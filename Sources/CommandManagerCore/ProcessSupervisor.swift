import Foundation

public enum RuntimeState: String, Equatable, Sendable {
    case stopped, starting, running, stopping, exited, failed, unknown

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .exited: return "Exited"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }

    public var isActive: Bool { self == .starting || self == .running || self == .stopping }
}

/// Live state of one service in this app session. Never persisted as configuration.
public struct RuntimeRecord: Equatable, Sendable {
    public var serviceID: UUID
    public var state: RuntimeState = .stopped
    public var pid: Int32?
    /// PID + kernel start time of the launched shell; used to recognise it after an app restart.
    public var processIdentity: ProcessIdentity?
    public var startedAt: Date?
    public var endedAt: Date?
    public var lastChange: Date = Date()
    public var exitCode: Int32?
    public var lastError: String?
    /// True once a graceful stop has exceeded the timeout; the UI may then offer Force Stop.
    public var stopTimedOut = false
    /// Consecutive automatic restarts (drives the backoff); reset by a manual action or a stable run.
    public var restartAttempt = 0
    /// When an automatic restart is scheduled after an exit/crash.
    public var nextRestartAt: Date?

    public init(serviceID: UUID) { self.serviceID = serviceID }
}

public enum SupervisorError: Error, LocalizedError, Equatable {
    case unknownService
    case disabled
    case alreadyActive
    case notRunning
    case stillActive
    case unverifiedProcess
    case shuttingDown

    public var errorDescription: String? {
        switch self {
        case .unknownService: return "This command no longer exists."
        case .disabled: return "This command is disabled. Enable it before starting."
        case .alreadyActive: return "This command is already running."
        case .notRunning: return "This command is not running."
        case .stillActive: return "Stop the command before deleting it."
        case .unverifiedProcess: return "A process from a previous session may still be running. Check it, then use Clear status before starting again."
        case .shuttingDown: return "Command Manager is quitting."
        }
    }
}

/// The single state machine owning every process the app launched.
@MainActor
public final class ProcessSupervisor: ObservableObject {
    @Published public private(set) var records: [UUID: RuntimeRecord] = [:]

    private let runner: CommandRunner
    private let logStore: LogStore
    private let stopTimeout: TimeInterval
    private let runtimeFileURL: URL?
    /// Environment every command starts from; replaced by the login-shell environment once captured.
    public var baseEnvironment: [String: String]
    private let identityProvider: (Int32) -> ProcessIdentity?
    private var handles: [UUID: ProcessHandle] = [:]
    /// Incremented on each launch so late callbacks from an earlier run are ignored.
    private var generations: [UUID: Int] = [:]
    private var pendingRestart: Set<UUID> = []
    /// PATH each service was last launched with, for the "command not found" hint.
    private var lastPATH: [UUID: String] = [:]
    private var stopTimers: [UUID: DispatchWorkItem] = [:]
    private var restartTimers: [UUID: DispatchWorkItem] = [:]
    /// Backoff for `restartOnExit`: first delay, doubled per consecutive restart, capped at max.
    public var restartBackoffMin: TimeInterval = 1
    public var restartBackoffMax: TimeInterval = 60
    /// A run lasting at least this long resets the backoff to `restartBackoffMin`.
    public var restartStableAfter: TimeInterval = 60
    /// Process groups whose shell already exited but whose other members were still alive.
    /// Pruned every second so an entry never outlives its group (a group ID may be reused once empty).
    private var leftoverGroups: [(id: UUID, handle: ProcessHandle)] = []
    private var pruneScheduled = false
    /// Interval for dropping emptied leftover groups.
    var leftoverPruneInterval: TimeInterval = 1
    /// Set by `stopAll()` when the app quits: nothing new may start after that.
    public private(set) var isShuttingDown = false

    /// Called on every state change (used for VoiceOver announcements).
    public var onStateChange: ((UUID, RuntimeState) -> Void)?
    /// Current saved definition, consulted when a pending restart fires (it may have been edited/disabled).
    public var definitionProvider: ((UUID) -> ServiceDefinition?)?

    public init(
        runner: CommandRunner,
        logStore: LogStore,
        stopTimeout: TimeInterval = 10,
        runtimeFileURL: URL? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        identityProvider: @escaping (Int32) -> ProcessIdentity? = ProcessIdentity.current(pid:)
    ) {
        self.identityProvider = identityProvider
        self.runner = runner
        self.logStore = logStore
        self.stopTimeout = stopTimeout
        self.runtimeFileURL = runtimeFileURL
        self.baseEnvironment = baseEnvironment
    }

    public func record(for id: UUID) -> RuntimeRecord {
        records[id] ?? RuntimeRecord(serviceID: id)
    }

    public var runningCount: Int { records.values.filter { $0.state == .running }.count }
    public var failedCount: Int { records.values.filter { $0.state == .failed }.count }

    // MARK: - Restore after app restart

    /// Marks services whose previous-session process may still be alive as `unknown`.
    /// The stale PID is only displayed; it is never signalled.
    public func restorePreviousSession(
        knownServiceIDs: Set<UUID>,
        isAlive: (ProcessIdentity) -> Bool = ProcessIdentity.isSameProcessAlive
    ) {
        guard let url = runtimeFileURL,
              let data = try? Data(contentsOf: url),
              let previous = try? JSONDecoder().decode([String: ProcessIdentity].self, from: data) else { return }
        for (key, identity) in previous {
            // Same PID *and* same start time, so a reused PID after reboot is not mistaken for ours.
            guard let id = UUID(uuidString: key), knownServiceIDs.contains(id), isAlive(identity) else { continue }
            let pid = identity.pid
            var record = RuntimeRecord(serviceID: id)
            record.state = .unknown
            record.pid = pid
            record.processIdentity = identity
            record.lastError = "A process (PID \(pid)) from a previous session is still running. Command Manager does not control it and will not stop it; check it manually (e.g. kill \(pid)), then use Clear status and Start."
            records[id] = record
        }
        persistRuntime()
    }

    // MARK: - Lifecycle

    public func start(_ definition: ServiceDefinition) throws {
        try start(definition, automatic: false)
    }

    private func start(_ definition: ServiceDefinition, automatic: Bool) throws {
        guard !isShuttingDown else { throw SupervisorError.shuttingDown }
        guard definition.isEnabled else { throw SupervisorError.disabled }
        let current = record(for: definition.id)
        guard !current.state.isActive else { throw SupervisorError.alreadyActive }
        // Starting again could duplicate a leftover process; the user must Clear status first.
        guard current.state != .unknown else { throw SupervisorError.unverifiedProcess }

        cancelScheduledRestart(definition.id)
        var record = current
        record.state = .starting
        record.nextRestartAt = nil
        if !automatic { record.restartAttempt = 0 }
        record.pid = nil
        record.processIdentity = nil
        record.exitCode = nil
        record.lastError = nil
        record.endedAt = nil
        record.stopTimedOut = false
        update(record)

        let generation = (generations[definition.id] ?? 0) + 1
        generations[definition.id] = generation
        let spec = LaunchSpec.make(for: definition, baseEnvironment: baseEnvironment)
        let id = definition.id
        lastPATH[id] = spec.environment["PATH"]
        logStore.appendEvent("Starting: \(spec.executable) \(spec.arguments.joined(separator: " ")) (cwd: \(spec.workingDirectory))", serviceID: id)

        // Spawn on the next main-loop turn so the UI can show `starting` first.
        DispatchQueue.main.async { [weak self] in
            self?.spawn(spec, id: id, generation: generation)
        }
    }

    private func spawn(_ spec: LaunchSpec, id: UUID, generation: Int) {
        guard generations[id] == generation, record(for: id).state == .starting else { return }
        let logStore = self.logStore
        do {
            let handle = try runner.launch(
                spec,
                onOutput: { source, data in logStore.append(data, source: source, serviceID: id) },
                onExit: { [weak self] termination in
                    DispatchQueue.main.async { self?.handleExit(id: id, generation: generation, termination: termination) }
                }
            )
            handles[id] = handle
            var record = self.record(for: id)
            record.state = .running
            record.pid = handle.pid
            record.processIdentity = identityProvider(handle.pid)
            record.startedAt = Date()
            update(record)
            logStore.appendEvent("Started with PID \(handle.pid)", serviceID: id)
        } catch {
            var record = self.record(for: id)
            record.state = .failed
            record.lastError = error.localizedDescription
            record.endedAt = Date()
            update(record)
            logStore.appendEvent("Start failed: \(error.localizedDescription)", serviceID: id)
        }
    }

    public func stop(_ id: UUID) throws {
        let current = record(for: id)
        if current.nextRestartAt != nil, !current.state.isActive {
            cancelScheduledRestart(id)
            var record = current
            record.nextRestartAt = nil
            record.restartAttempt = 0
            update(record)
            logStore.appendEvent("Automatic restart cancelled", serviceID: id)
            return
        }
        guard current.state == .running, let handle = handles[id] else { throw SupervisorError.notRunning }
        var record = current
        record.state = .stopping
        record.stopTimedOut = false
        update(record)
        logStore.appendEvent("Stopping (SIGTERM to process group \(handle.pid))", serviceID: id)
        handle.terminate()

        let generation = generations[id]
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.generations[id] == generation, self.record(for: id).state == .stopping else { return }
            var record = self.record(for: id)
            record.stopTimedOut = true
            self.update(record)
            self.logStore.appendEvent("Still running after \(Int(self.stopTimeout))s; Force Stop is available.", serviceID: id)
        }
        stopTimers[id]?.cancel()
        stopTimers[id] = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + stopTimeout, execute: timer)
    }

    /// Only offered by the UI after a graceful stop timed out and the user confirmed.
    public func forceStop(_ id: UUID) throws {
        guard record(for: id).state == .stopping, let handle = handles[id] else { throw SupervisorError.notRunning }
        logStore.appendEvent("Force stopping (SIGKILL to process group \(handle.pid))", serviceID: id)
        handle.forceKill()
    }

    public func restart(_ definition: ServiceDefinition) throws {
        guard !isShuttingDown else { throw SupervisorError.shuttingDown }
        guard definition.isEnabled else { throw SupervisorError.disabled }
        guard record(for: definition.id).state == .running else { throw SupervisorError.notRunning }
        try stop(definition.id)
        pendingRestart.insert(definition.id)
    }

    /// True while any process launched in this session (or a leftover member of its group) is alive.
    public var hasLiveProcesses: Bool {
        leftoverGroups.removeAll { !$0.handle.groupStillAlive }
        return !handles.isEmpty || !leftoverGroups.isEmpty
    }

    /// SIGKILL to every process group still owned (last resort when the app quits).
    public func forceKillAll() {
        for (id, handle) in handles {
            logStore.appendEvent("Force stopping on quit (SIGKILL to process group \(handle.pid))", serviceID: id)
            handle.forceKill()
        }
        for (id, handle) in leftoverGroups where handle.groupStillAlive {
            logStore.appendEvent("Force stopping leftover process group \(handle.pid) on quit", serviceID: id)
            handle.signalRemainingGroup(SIGKILL)
        }
    }

    /// Gracefully stops everything this session launched (used when the app quits).
    /// After this, nothing can start again (including pending restarts).
    public func stopAll() {
        isShuttingDown = true
        pendingRestart.removeAll()
        for id in Array(restartTimers.keys) { cancelScheduledRestart(id) }
        for (id, handle) in leftoverGroups where handle.groupStillAlive {
            logStore.appendEvent("Stopping leftover process group \(handle.pid) on quit (SIGTERM)", serviceID: id)
            handle.signalRemainingGroup(SIGTERM)
        }
        for (id, record) in records where record.state == .running {
            try? stop(id)
        }
        for (id, record) in records where record.state == .starting {
            generations[id, default: 0] += 1
            var r = record
            r.state = .stopped
            update(r)
        }
    }

    /// Clears an `unknown`/ended record back to `stopped` (no signal is sent).
    public func clearStatus(_ id: UUID) {
        guard !record(for: id).state.isActive else { return }
        cancelScheduledRestart(id)
        var record = RuntimeRecord(serviceID: id)
        record.state = .stopped
        update(record)
    }

    /// Removes runtime state for a deleted service. Refused while a process is still owned,
    /// so nothing the app launched can become invisible and unstoppable.
    public func forget(_ id: UUID) throws {
        guard !record(for: id).state.isActive, handles[id] == nil else { throw SupervisorError.stillActive }
        generations[id, default: 0] += 1
        pendingRestart.remove(id)
        stopTimers.removeValue(forKey: id)?.cancel()
        cancelScheduledRestart(id)
        records[id] = nil
        persistRuntime()
    }

    private func handleExit(id: UUID, generation: Int, termination: Termination) {
        logStore.flush(serviceID: id)
        // A late callback from an earlier run must not touch the current run's handle or timer.
        guard generations[id] == generation, records[id] != nil else { return }
        let handle = handles.removeValue(forKey: id)
        stopTimers.removeValue(forKey: id)?.cancel()

        var record = self.record(for: id)
        let wasStopping = record.state == .stopping
        if let handle, handle.groupStillAlive {
            leftoverGroups.append((id, handle))
            scheduleLeftoverPrune()
            if wasStopping {
                // The shell exited but children in its group are still alive; finish the stop:
                // SIGTERM again, SIGKILL only after a grace period.
                logStore.appendEvent("Processes left in group \(handle.pid) after the shell exited; sending SIGTERM", serviceID: id)
                handle.signalRemainingGroup(SIGTERM)
                DispatchQueue.main.asyncAfter(deadline: .now() + min(stopTimeout, 3)) { [weak self] in
                    guard handle.groupStillAlive else { return }
                    self?.logStore.appendEvent("Group \(handle.pid) still alive; sending SIGKILL", serviceID: id)
                    handle.signalRemainingGroup(SIGKILL)
                }
            } else {
                logStore.appendEvent("Warning: background processes from this command are still running (process group \(handle.pid)). They will be stopped when Command Manager quits.", serviceID: id)
            }
        }
        record.pid = nil
        record.processIdentity = nil
        record.endedAt = Date()
        record.stopTimedOut = false
        switch termination {
        case .exited(let code):
            record.exitCode = code
            if wasStopping {
                record.state = .stopped
            } else if code == 0 {
                record.state = .exited
            } else {
                record.state = .failed
                record.lastError = "Exited with code \(code)."
                if code == 127 {
                    record.lastError = "Exited with code 127: command or file not found. Check the spelling and full path (e.g. /Users/…, not /User/…), or add its folder to PATH."
                }
            }
            logStore.appendEvent("Exited with code \(code)", serviceID: id)
            if code == 127, !wasStopping {
                logStore.appendEvent("Hint: 127 means the shell could not find the program. PATH was: \(lastPATH[id] ?? "?")", serviceID: id)
            }
        case .signaled(let signal):
            record.exitCode = nil
            if wasStopping {
                record.state = .stopped
            } else {
                record.state = .failed
                record.lastError = "Terminated by signal \(signal) (stopped outside Command Manager)."
            }
            logStore.appendEvent("Terminated by signal \(signal)", serviceID: id)
        }
        update(record)

        if !wasStopping, !pendingRestart.contains(id) { scheduleAutomaticRestart(id) }

        if pendingRestart.remove(id) != nil, !isShuttingDown {
            // Use the definition as saved now: it may have been edited or disabled meanwhile.
            guard let definition = definitionProvider?(id) else { return }
            do { try start(definition) } catch {
                var record = self.record(for: id)
                record.lastError = "Restart skipped: \(error.localizedDescription)"
                update(record)
            }
        }
    }

    // MARK: - Automatic restart (restartOnExit)

    /// Delay before automatic restart number `attempt` (0-based): min·2^attempt, capped at max.
    public func restartDelay(attempt: Int) -> TimeInterval {
        min(restartBackoffMax, restartBackoffMin * pow(2, Double(min(attempt, 30))))
    }

    private func scheduleAutomaticRestart(_ id: UUID) {
        guard !isShuttingDown, let definition = definitionProvider?(id),
              definition.restartOnExit, definition.isEnabled else { return }
        var record = self.record(for: id)
        if let started = record.startedAt, let ended = record.endedAt,
           ended.timeIntervalSince(started) >= restartStableAfter {
            record.restartAttempt = 0
        }
        let delay = restartDelay(attempt: record.restartAttempt)
        record.restartAttempt += 1
        record.nextRestartAt = Date().addingTimeInterval(delay)
        update(record)
        logStore.appendEvent("Restarting in \(Self.format(delay)) (automatic restart #\(record.restartAttempt))", serviceID: id)

        let generation = generations[id]
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartTimers[id] = nil
            let current = self.record(for: id)
            guard self.generations[id] == generation, current.nextRestartAt != nil, !current.state.isActive,
                  !self.isShuttingDown else { return }
            guard let latest = self.definitionProvider?(id), latest.restartOnExit, latest.isEnabled else {
                var r = current
                r.nextRestartAt = nil
                self.update(r)
                return
            }
            do { try self.start(latest, automatic: true) } catch {
                var r = self.record(for: id)
                r.nextRestartAt = nil
                r.lastError = "Automatic restart failed: \(error.localizedDescription)"
                self.update(r)
            }
        }
        cancelScheduledRestart(id)
        restartTimers[id] = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    /// Called after definitions change: drops a scheduled restart that is no longer wanted
    /// (restart turned off, command disabled or deleted).
    public func definitionsChanged() {
        for id in Array(restartTimers.keys) {
            let wanted = definitionProvider?(id).map { $0.restartOnExit && $0.isEnabled } ?? false
            guard !wanted else { continue }
            cancelScheduledRestart(id)
            if var r = records[id] {
                r.nextRestartAt = nil
                update(r)
                logStore.appendEvent("Automatic restart cancelled", serviceID: id)
            }
        }
    }

    private func cancelScheduledRestart(_ id: UUID) {
        restartTimers.removeValue(forKey: id)?.cancel()
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds < 10 && seconds.rounded() != seconds ? String(format: "%.1fs", seconds) : "\(Int(seconds.rounded()))s"
    }

    /// Drops leftover groups as soon as they are empty, so a later reuse of the same group ID by an
    /// unrelated process is never signalled.
    private func scheduleLeftoverPrune() {
        guard !pruneScheduled else { return }
        pruneScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + leftoverPruneInterval) { [weak self] in
            guard let self else { return }
            self.pruneScheduled = false
            self.leftoverGroups.removeAll { !$0.handle.groupStillAlive }
            if !self.leftoverGroups.isEmpty { self.scheduleLeftoverPrune() }
        }
    }

    /// Number of tracked leftover groups (for diagnostics/tests).
    var leftoverGroupCount: Int { leftoverGroups.count }

    private func update(_ record: RuntimeRecord) {
        var record = record
        let previous = records[record.serviceID]?.state
        record.lastChange = Date()
        records[record.serviceID] = record
        persistRuntime()
        if previous != record.state { onStateChange?(record.serviceID, record.state) }
    }

    /// Records PIDs of live processes so a later session can flag them as `unknown`.
    private func persistRuntime() {
        guard let url = runtimeFileURL else { return }
        var pids: [String: ProcessIdentity] = [:]
        for (id, record) in records where record.state.isActive || record.state == .unknown {
            if let identity = record.processIdentity { pids[id.uuidString] = identity }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pids).write(to: url, options: .atomic)
    }
}
