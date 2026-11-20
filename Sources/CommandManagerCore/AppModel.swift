import Foundation
import Combine

/// File locations under Application Support.
public struct AppPaths: Sendable {
    public let root: URL
    public var servicesFile: URL { root.appendingPathComponent("services.json") }
    public var runtimeFile: URL { root.appendingPathComponent("runtime.json") }
    public var logsDirectory: URL { root.appendingPathComponent("Logs", isDirectory: true) }

    public init(root: URL) { self.root = root }

    /// `CMGR_HOME` (used by `cmgr` and for testing) overrides the default data folder.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let home = environment["CMGR_HOME"], !home.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: support.appendingPathComponent("CommandManager", isDirectory: true))
    }
}

/// Facade the SwiftUI views depend on: definitions + runtime + login item.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var services: [ServiceDefinition] = []
    /// Groups and the top-level order of the list.
    @Published public private(set) var layout = ListLayout()
    /// Non-modal banner text (load/save/start failures). Cleared by the user.
    @Published public var banner: String?
    @Published public private(set) var loginItemStatus: LoginItemStatus

    public let supervisor: ProcessSupervisor
    public let logStore: LogStore
    public let paths: AppPaths
    private let store: ServiceStore
    private let loginItem: LoginItemManaging
    private var cancellables: Set<AnyCancellable> = []
    /// Called once the command environment (login-shell PATH etc.) is known after `launch`.
    public var onEnvironmentReady: (([String: String]) -> Void)?

    public init(
        paths: AppPaths,
        runner: CommandRunner = PosixCommandRunner(),
        loginItem: LoginItemManaging,
        stopTimeout: TimeInterval = 10,
        identityProvider: @escaping (Int32) -> ProcessIdentity? = ProcessIdentity.current(pid:)
    ) {
        self.paths = paths
        self.store = ServiceStore(fileURL: paths.servicesFile)
        self.logStore = LogStore(directory: paths.logsDirectory)
        self.supervisor = ProcessSupervisor(
            runner: runner, logStore: logStore, stopTimeout: stopTimeout, runtimeFileURL: paths.runtimeFile,
            identityProvider: identityProvider
        )
        self.loginItem = loginItem
        self.loginItemStatus = loginItem.status
        // Re-publish runtime changes so views observing the model refresh.
        supervisor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        supervisor.definitionProvider = { [weak self] id in self?.service(id) }
    }

    /// App launch: load definitions, flag unverifiable leftovers, capture the user's login-shell
    /// environment (PATH etc. as in Terminal), then auto-start eligible commands.
    /// `shellEnvironment` runs off the main thread; pass nil to keep the app environment.
    public func launch(
        shellEnvironment: (@Sendable () -> [String: String]?)? = nil
    ) {
        let loaded = store.load()
        applyLoaded(loaded.services)
        if let error = loaded.error { banner = error.localizedDescription }
        supervisor.restorePreviousSession(knownServiceIDs: Set(services.map(\.id)))
        refreshLoginItemStatus()
        guard let shellEnvironment else {
            autoStart()
            onEnvironmentReady?(supervisor.baseEnvironment)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let captured = shellEnvironment()
            DispatchQueue.main.async {
                guard let self else { return }
                if captured == nil {
                    self.banner = "Could not read your login shell environment (\(LoginShellEnvironment.userShell())); commands use the app environment, so tools set up in your shell profile may not be found."
                }
                self.supervisor.baseEnvironment = LoginShellEnvironment.merged(
                    app: self.supervisor.baseEnvironment, shell: captured)
                self.autoStart()
                self.onEnvironmentReady?(self.supervisor.baseEnvironment)
            }
        }
    }

    /// Loads saved definitions only — no runtime restore, no auto-start. Used by `cmgr` to edit
    /// definitions while the app is not running. Returns the load error, if any.
    @discardableResult
    public func loadDefinitionsOnly() -> Error? {
        let loaded = store.load()
        applyLoaded(loaded.services)
        return loaded.error
    }

    private func applyLoaded(_ loadedServices: [ServiceDefinition]) {
        var s = loadedServices
        var l = store.loadedLayout
        l.normalize(services: &s)
        services = s
        layout = l
    }

    private func autoStart() {
        for definition in services where definition.shouldAutoStart {
            guard supervisor.record(for: definition.id).state != .unknown else { continue }
            try? supervisor.start(definition)
        }
    }

    public func service(_ id: UUID) -> ServiceDefinition? { services.first { $0.id == id } }

    public func record(_ id: UUID) -> RuntimeRecord { supervisor.record(for: id) }

    public var runningCount: Int { supervisor.runningCount }
    public var failedCount: Int { supervisor.failedCount }

    // MARK: - CRUD

    public func validate(_ draft: ServiceDraft, editing id: UUID?) -> [ValidationIssue] {
        ServiceValidator.validate(draft, existing: services, editingID: id)
    }

    /// Saves a new or edited definition. Saving never starts the command.
    @discardableResult
    public func save(_ draft: ServiceDraft, editing id: UUID?) -> Result<ServiceDefinition, Error> {
        let original = id.flatMap(service)
        switch ServiceValidator.makeDefinition(from: draft, existing: services, editing: original) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let definition):
            var updated = services
            if let index = updated.firstIndex(where: { $0.id == definition.id }) {
                updated[index] = definition
            } else {
                updated.append(definition)
            }
            do {
                try commit(updated)
                return .success(definition)
            } catch {
                return .failure(error)
            }
        }
    }

    /// Removes the definition and its auto-start flag. Refused while the command is running so its
    /// process never becomes untracked. Never touches the working directory; log files stay on disk.
    public func delete(_ id: UUID) throws {
        guard !supervisor.record(for: id).state.isActive else { throw SupervisorError.stillActive }
        try commit(services.filter { $0.id != id })
        try? supervisor.forget(id)
    }

    public func setEnabled(_ enabled: Bool, for id: UUID) throws {
        try mutate(id) { $0.isEnabled = enabled }
    }

    public func setAutoStart(_ autoStart: Bool, for id: UUID) throws {
        try mutate(id) { $0.autoStart = autoStart }
    }

    /// Moves a command to `index` (0-based, clamped) within where it is now: its group, or the top level.
    public func move(_ id: UUID, to index: Int) throws {
        guard let d = service(id) else { throw SupervisorError.unknownService }
        try place(id, inGroup: d.groupID, at: index)
    }

    // MARK: - Groups and list order

    /// The list as displayed: top-level rows, groups carrying their members in order.
    public var rows: [ListRow] {
        layout.order.compactMap { item in
            switch item {
            case .group(let id):
                return layout.group(id).map { .group($0, members: members(of: id)) }
            case .service(let id):
                return service(id).map { .service($0) }
            }
        }
    }

    /// Commands in display order (groups expanded in place).
    public var orderedServices: [ServiceDefinition] {
        rows.flatMap { row -> [ServiceDefinition] in
            switch row {
            case .group(_, let members): return members
            case .service(let s): return [s]
            }
        }
    }

    public func members(of groupID: UUID) -> [ServiceDefinition] { services.filter { $0.groupID == groupID } }

    public func group(_ id: UUID) -> ServiceGroup? { layout.group(id) }

    /// Puts a command into `group` (nil = top level) at `index` (0-based, clamped) inside it.
    public func place(_ id: UUID, inGroup groupID: UUID?, at index: Int) throws {
        guard var d = service(id) else { throw SupervisorError.unknownService }
        if let groupID, layout.group(groupID) == nil { throw ControlError("That group no longer exists.") }
        var updatedServices = services.filter { $0.id != id }
        var updatedLayout = layout
        updatedLayout.order.removeAll { $0 == .service(id) }
        if d.groupID != groupID { d.updatedAt = Date() }
        d.groupID = groupID
        if let groupID {
            var members = updatedServices.filter { $0.groupID == groupID }
            members.insert(d, at: min(max(index, 0), members.count))
            updatedServices = updatedServices.filter { $0.groupID != groupID } + members
        } else {
            updatedServices.append(d)
            updatedLayout.order.insert(.service(id), at: min(max(index, 0), updatedLayout.order.count))
        }
        guard updatedServices != services || updatedLayout != layout else { return }
        try commit(updatedServices, updatedLayout)
    }

    /// Moves a group to `index` (0-based, clamped) among the top-level rows.
    public func moveGroup(_ id: UUID, to index: Int) throws {
        guard layout.group(id) != nil else { throw ControlError("That group no longer exists.") }
        var updated = layout
        updated.order.removeAll { $0 == .group(id) }
        updated.order.insert(.group(id), at: min(max(index, 0), updated.order.count))
        guard updated != layout else { return }
        try commit(services, updated)
    }

    /// Top-level index of a row (group or ungrouped command).
    public func topIndex(of item: ListItem) -> Int? { layout.order.firstIndex(of: item) }

    @discardableResult
    public func createGroup(named name: String, with serviceIDs: [UUID] = [], at index: Int? = nil) throws -> ServiceGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ControlError("Group name is required.") }
        let group = ServiceGroup(name: uniqueGroupName(trimmed), isCollapsed: serviceIDs.isEmpty)
        var updated = layout
        updated.groups.append(group)
        let position = index ?? serviceIDs.compactMap { topIndex(of: .service($0)) }.min() ?? updated.order.count
        updated.order.insert(.group(group.id), at: min(max(position, 0), updated.order.count))
        var updatedServices = services
        for i in updatedServices.indices where serviceIDs.contains(updatedServices[i].id) {
            updatedServices[i].groupID = group.id
        }
        try commit(updatedServices, updated)
        return group
    }

    public func renameGroup(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ControlError("Group name is required.") }
        guard let index = layout.groups.firstIndex(where: { $0.id == id }) else { throw ControlError("That group no longer exists.") }
        var updated = layout
        updated.groups[index].name = trimmed
        try commit(services, updated)
    }

    public func setGroupCollapsed(_ id: UUID, _ collapsed: Bool) throws {
        guard let index = layout.groups.firstIndex(where: { $0.id == id }), layout.groups[index].isCollapsed != collapsed else { return }
        var updated = layout
        updated.groups[index].isCollapsed = collapsed
        try commit(services, updated)
    }

    /// Removes the group; its commands stay, at the group's place in the top level.
    public func ungroup(_ id: UUID) throws {
        guard let position = topIndex(of: .group(id)) else { throw ControlError("That group no longer exists.") }
        var updated = layout
        let memberIDs = members(of: id).map(\.id)
        updated.groups.removeAll { $0.id == id }
        updated.order.remove(at: position)
        updated.order.insert(contentsOf: memberIDs.map { .service($0) }, at: position)
        var updatedServices = services
        for i in updatedServices.indices where updatedServices[i].groupID == id { updatedServices[i].groupID = nil }
        try commit(updatedServices, updated)
    }

    /// Starts every enabled, startable member; returns how many were started.
    @discardableResult
    public func startGroup(_ id: UUID) -> Int {
        var started = 0
        for d in members(of: id) where d.isEnabled {
            let state = record(d.id).state
            guard !state.isActive, state != .unknown else { continue }
            if (try? supervisor.start(d)) != nil { started += 1 }
        }
        return started
    }

    /// Stops every running member (and cancels scheduled automatic restarts); returns how many.
    @discardableResult
    public func stopGroup(_ id: UUID) -> Int {
        var stopped = 0
        for d in members(of: id) {
            let r = record(d.id)
            guard r.state == .running || r.nextRestartAt != nil else { continue }
            if (try? supervisor.stop(d.id)) != nil { stopped += 1 }
        }
        return stopped
    }

    private func uniqueGroupName(_ base: String) -> String {
        let taken = Set(layout.groups.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    public func setRestartOnExit(_ restart: Bool, for id: UUID) throws {
        try mutate(id) { $0.restartOnExit = restart }
    }

    private func mutate(_ id: UUID, _ change: (inout ServiceDefinition) -> Void) throws {
        guard let index = services.firstIndex(where: { $0.id == id }) else { throw SupervisorError.unknownService }
        var updated = services
        change(&updated[index])
        updated[index].updatedAt = Date()
        try commit(updated)
    }

    private func commit(_ updated: [ServiceDefinition]) throws {
        try commit(updated, layout)
    }

    private func commit(_ updated: [ServiceDefinition], _ newLayout: ListLayout) throws {
        var s = updated
        var l = newLayout
        l.normalize(services: &s)
        try store.save(s, layout: l)
        services = s
        layout = l
        supervisor.definitionsChanged()
    }

    // MARK: - Lifecycle actions (errors become the banner)

    public func start(_ id: UUID) {
        perform { guard let d = service(id) else { throw SupervisorError.unknownService }; try supervisor.start(d) }
    }

    public func stop(_ id: UUID) { perform { try supervisor.stop(id) } }
    public func forceStop(_ id: UUID) { perform { try supervisor.forceStop(id) } }
    public func clearStatus(_ id: UUID) { supervisor.clearStatus(id) }

    public func restart(_ id: UUID) {
        perform { guard let d = service(id) else { throw SupervisorError.unknownService }; try supervisor.restart(d) }
    }

    /// Quit: SIGTERM everything, wait up to `grace` for exits, then SIGKILL what is left.
    /// Commands must not keep running without the app.
    public func stopAllForQuit(grace: TimeInterval = 3, completion: @escaping @MainActor () -> Void) {
        // A second quit request while the first is still waiting must not start another poll.
        guard !supervisor.isShuttingDown else { return }
        supervisor.stopAll()
        let deadline = Date().addingTimeInterval(grace)
        func poll() {
            if !supervisor.hasLiveProcesses {
                logStore.sync()
                completion()
            } else if Date() >= deadline {
                supervisor.forceKillAll()
                logStore.sync()
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }
            }
        }
        poll()
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { banner = error.localizedDescription }
    }

    // MARK: - Login item

    public func refreshLoginItemStatus() { loginItemStatus = loginItem.status }

    public func setOpenAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            banner = error.localizedDescription
        }
        // Always re-read: never claim a state macOS did not accept.
        refreshLoginItemStatus()
    }
}
