import AppKit
import CommandManagerCore
import SwiftUI
import UniformTypeIdentifiers

/// What is being dragged inside the list.
enum DragItem: Equatable {
    case service(UUID)
    case group(UUID)
}

struct ServiceListView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var popoverController: PopoverController
    @EnvironmentObject var logViewers: LogViewerWindows
    @Binding var route: Route
    @State private var rowsHeight: CGFloat = 0
    /// Row being dragged to a new place (nil when not reordering).
    @State private var dragging: DragItem?
    /// Group whose header is under a dragged command (it will go inside).
    @State private var dropIntoGroup: UUID?
    @State private var renamingGroup: UUID?

    /// The list grows with its rows between these heights, then scrolls.
    static let minListHeight: CGFloat = 50
    static let maxListHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.services.isEmpty && model.layout.groups.isEmpty {
                emptyState
            } else {
                // No scroll indicator: it flashed while the list resized and made it look jumpy.
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            switch row {
                            case .group(let group, let members):
                                groupHeader(group, members: members)
                                Divider()
                                if !group.isCollapsed {
                                    ForEach(members) { service in
                                        serviceRow(service, group: group.id)
                                        Divider().padding(.leading, 28)
                                    }
                                }
                            case .service(let service):
                                serviceRow(service, group: nil)
                                Divider()
                            }
                        }
                        // Dropping below the last row moves the item to the end of the top level.
                        Color.clear.frame(height: 10)
                            .onDrop(of: [UTType.text, UTType.fileURL], delegate: delegate(.end))
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: RowsHeightKey.self, value: proxy.size.height)
                    })
                }
                .frame(height: min(max(rowsHeight, Self.minListHeight), Self.maxListHeight))
                .onPreferenceChange(RowsHeightKey.self) { rowsHeight = $0 }
            }
            Divider()
            FooterView(route: $route)
        }
    }

    // MARK: Rows

    private func serviceRow(_ service: ServiceDefinition, group: UUID?) -> some View {
        ServiceRow(service: service, record: model.record(service.id), route: $route)
            .padding(.leading, group == nil ? 0 : 16)
            .opacity(dragging == .service(service.id) ? 0.4 : 1)
            .onDrag {
                beginDrag(.service(service.id))
                return NSItemProvider(object: service.id.uuidString as NSString)
            }
            .onDrop(of: [UTType.text, UTType.fileURL], delegate: delegate(.service(service.id, group: group)))
            .contextMenu { serviceMenu(service) }
    }

    private func groupHeader(_ group: ServiceGroup, members: [ServiceDefinition]) -> some View {
        GroupHeaderRow(group: group, members: members, isRenaming: renamingGroup == group.id,
                       isDropTarget: dropIntoGroup == group.id,
                       onToggle: { run { try model.setGroupCollapsed(group.id, !group.isCollapsed) } },
                       onRename: { name in
                           renamingGroup = nil
                           if let name { run { try model.renameGroup(group.id, to: name) } }
                       })
            .frame(height: GroupHeaderRow.height)
            .opacity(dragging == .group(group.id) ? 0.4 : 1)
            .onDrag {
                beginDrag(.group(group.id))
                return NSItemProvider(object: group.id.uuidString as NSString)
            }
            .onDrop(of: [UTType.text, UTType.fileURL], delegate: delegate(.groupHeader(group.id)))
            .contextMenu { groupMenu(group, members: members) }
    }

    private func delegate(_ target: ListDropDelegate.Target) -> ListDropDelegate {
        ListDropDelegate(target: target, dragging: $dragging, dropIntoGroup: $dropIntoGroup, model: model,
                         onFile: { url in popoverController.handleDrop(url, model: model) })
    }

    /// Clears the drag state once the mouse is released, even if the drop landed outside the list.
    private func beginDrag(_ item: DragItem) {
        dragging = item
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    dragging = nil
                    dropIntoGroup = nil
                } else {
                    poll()
                }
            }
        }
        poll()
    }

    // MARK: Menus

    @ViewBuilder private func serviceMenu(_ service: ServiceDefinition) -> some View {
        let siblings = service.groupID.map { model.members(of: $0).map(\.id) }
            ?? model.layout.order.compactMap { if case .service(let id) = $0 { return id } else { return nil } }
        let index = siblings.firstIndex(of: service.id) ?? 0
        let last = siblings.count - 1
        Button("Show Log") { logViewers.open(service.id) }
        Divider()
        Button("Move to Top") { move(service.id, 0) }.disabled(index == 0)
        Button("Move Up") { move(service.id, index - 1) }.disabled(index == 0)
        Button("Move Down") { move(service.id, index + 1) }.disabled(index >= last)
        Button("Move to Bottom") { move(service.id, last) }.disabled(index >= last)
        Divider()
        Menu("Group") {
            Button("No Group") { place(service.id, nil) }.disabled(service.groupID == nil)
            if !model.layout.groups.isEmpty { Divider() }
            ForEach(model.layout.groups) { g in
                Button((service.groupID == g.id ? "✓ " : "") + g.name) { place(service.id, g.id) }
                    .disabled(service.groupID == g.id)
            }
            Divider()
            Button("New Group with This…") { newGroup(with: [service.id]) }
        }
    }

    @ViewBuilder private func groupMenu(_ group: ServiceGroup, members: [ServiceDefinition]) -> some View {
        Button("Start All") { _ = model.startGroup(group.id) }.disabled(members.isEmpty)
        Button("Stop All") { _ = model.stopGroup(group.id) }.disabled(members.isEmpty)
        Button("Show Group Log") { logViewers.openGroup(group.id) }.disabled(members.isEmpty)
        Divider()
        Button("Add Command Here…") { route = .addPrefilled(ServiceDraft(groupID: group.id)) }
        Button("Rename…") { renamingGroup = group.id }
        Button("Ungroup") { run { try model.ungroup(group.id) } }
        Divider()
        let index = model.topIndex(of: .group(group.id)) ?? 0
        let last = model.layout.order.count - 1
        Button("Move to Top") { run { try model.moveGroup(group.id, to: 0) } }.disabled(index == 0)
        Button("Move Up") { run { try model.moveGroup(group.id, to: index - 1) } }.disabled(index == 0)
        Button("Move Down") { run { try model.moveGroup(group.id, to: index + 1) } }.disabled(index >= last)
        Button("Move to Bottom") { run { try model.moveGroup(group.id, to: last) } }.disabled(index >= last)
    }

    private func move(_ id: UUID, _ index: Int) { run { try model.move(id, to: index) } }

    private func place(_ id: UUID, _ group: UUID?) {
        run { try model.place(id, inGroup: group, at: group.map { model.members(of: $0).count } ?? model.layout.order.count) }
    }

    private func newGroup(with ids: [UUID] = []) {
        run {
            let g = try model.createGroup(named: "New Group", with: ids)
            renamingGroup = g.id
        }
    }

    private func run(_ action: () throws -> Void) {
        withAnimation(.easeInOut(duration: 0.15)) {
            do { try action() } catch { model.banner = error.localizedDescription }
        }
    }

    // MARK: Header / empty

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command Manager").font(.headline)
                let failed = model.failedCount
                (Text("\(model.runningCount) running · ")
                    + Text("\(failed) failed").foregroundColor(failed > 0 ? .red : .secondary)
                    + Text(" · \(model.services.count) commands"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button { newGroup() } label: { Image(systemName: "folder.badge.plus") }
                .help("New group")
                .accessibilityLabel("New group")
            Button {
                route = .add
            } label: {
                Label("Add", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Add command (⌘N)")
            .accessibilityLabel("Add command")
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text("No commands yet").font(.title3)
            Text("Or drop a script, app or project folder here.")
                .foregroundColor(.secondary)
            Button("Add command") { route = .add }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

/// Collapsible group row: tap to show/hide its commands, quick start/stop for all of them.
struct GroupHeaderRow: View {
    static let height: CGFloat = 38

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var logViewers: LogViewerWindows
    let group: ServiceGroup
    let members: [ServiceDefinition]
    let isRenaming: Bool
    let isDropTarget: Bool
    let onToggle: () -> Void
    /// New name, or nil when renaming was cancelled.
    let onRename: (String?) -> Void

    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @State private var hovering = false

    private var running: Int { members.filter { model.record($0.id).state == .running }.count }
    private var failed: Int { members.filter { model.record($0.id).state == .failed }.count }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .foregroundColor(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
            Image(systemName: group.isCollapsed ? "folder.fill" : "folder")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            if isRenaming {
                TextField("Group name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { onRename(draftName) }
                    .onExitCommand { onRename(nil) }
                    .onAppear { draftName = group.name; nameFocused = true }
            } else {
                Text(group.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(members.count)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    .padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.15)))
                if running > 0 {
                    Label("\(running)", systemImage: "play.circle.fill").font(.caption).foregroundColor(.green)
                        .accessibilityLabel("\(running) running")
                }
                if failed > 0 {
                    Label("\(failed)", systemImage: "xmark.octagon.fill").font(.caption).foregroundColor(.red)
                        .accessibilityLabel("\(failed) failed")
                }
            }
            Spacer()
            if !isRenaming {
                LogButton(help: "Show the merged log of every command in \(group.name)",
                          label: "Show log of group \(group.name)") { logViewers.openGroup(group.id) }
                    .disabled(members.isEmpty)
                if running > 0 {
                    Button { model.stopGroup(group.id) } label: { Image(systemName: "stop.fill") }
                        .help("Stop all in \(group.name)")
                        .accessibilityLabel("Stop all in \(group.name)")
                } else {
                    Button { model.startGroup(group.id) } label: { Image(systemName: "play.fill") }
                        .disabled(!members.contains { $0.isEnabled })
                        .help("Start all in \(group.name)")
                        .accessibilityLabel("Start all in \(group.name)")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(isDropTarget ? Color.accentColor.opacity(0.18)
                    : Color.secondary.opacity(hovering ? 0.14 : 0.06))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isRenaming { onToggle() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Group \(group.name), \(members.count) commands, \(group.isCollapsed ? "collapsed" : "expanded")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
    }
}

struct ServiceRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var logViewers: LogViewerWindows
    let service: ServiceDefinition
    let record: RuntimeRecord
    @Binding var route: Route
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
                .help("Drag to reorder")
                .accessibilityHidden(true)
            Button {
                route = .detail(service.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(service.displayName)
                                .font(.body.weight(.medium))
                                .foregroundColor(service.isEnabled ? .primary : .secondary)
                                .lineLimit(1)
                            if !service.isEnabled {
                                Text("Disabled").font(.caption2).padding(.horizontal, 4)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary))
                            }
                            if service.restartOnExit {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.caption2).foregroundColor(.secondary)
                                    .help("Restarts automatically when it exits or crashes")
                                    .accessibilityLabel("Auto-restart")
                            }
                            if service.autoStart {
                                Image(systemName: "bolt.fill").font(.caption2).foregroundColor(.secondary)
                                    .help("Starts when Command Manager opens")
                                    .accessibilityLabel("Auto-start")
                            }
                        }
                        HStack(spacing: 8) {
                            StatusBadge(state: record.state)
                            if let pid = record.pid {
                                Text("PID \(String(pid))").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            }
                            if let next = record.nextRestartAt {
                                (Text("restart in ") + Text(next, style: .timer))
                                    .font(.caption.monospacedDigit()).foregroundColor(.orange)
                            }
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Shows details and log")

            LogButton(help: "Show log", label: "Show log of \(service.displayName)") { logViewers.open(service.id) }
            quickAction
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var accessibilityText: String {
        var parts = [service.displayName, record.state.label]
        if let pid = record.pid { parts.append("PID \(pid)") }
        if !service.isEnabled { parts.append("disabled") }
        if service.autoStart { parts.append("auto-start") }
        if record.nextRestartAt != nil { parts.append("restarting automatically") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var quickAction: some View {
        switch record.state {
        case .running:
            HStack(spacing: 6) {
                Button { model.restart(service.id) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!service.isEnabled)
                    .help("Restart")
                    .accessibilityLabel("Restart \(service.displayName)")
                Button { model.stop(service.id) } label: { Image(systemName: "stop.fill") }
                    .help("Stop")
                    .accessibilityLabel("Stop \(service.displayName)")
            }
        case _ where record.nextRestartAt != nil:
            Button { model.stop(service.id) } label: { Image(systemName: "stop.fill") }
                .help("Cancel the automatic restart")
                .accessibilityLabel("Cancel automatic restart of \(service.displayName)")
        case .starting, .stopping:
            ProgressView().controlSize(.small).accessibilityLabel(record.state.label)
        default:
            Button { model.start(service.id) } label: { Image(systemName: "play.fill") }
                .disabled(!service.isEnabled || record.state == .unknown)
                .help(service.isEnabled ? "Start" : "Enable this command to start it")
                .accessibilityLabel("Start \(service.displayName)")
        }
    }
}

/// Live reordering while dragging. A command dropped on a command takes its place (joining or
/// leaving a group as needed); on a group header it goes before the group (upper half) or inside it
/// (lower half). Groups reorder among top-level rows. Files from Finder go to the add-by-drop flow.
struct ListDropDelegate: DropDelegate {
    enum Target {
        case service(UUID, group: UUID?)
        case groupHeader(UUID)
        case end
    }

    let target: Target
    @Binding var dragging: DragItem?
    @Binding var dropIntoGroup: UUID?
    let model: AppModel
    let onFile: @MainActor (URL) -> Void

    func dropEntered(info: DropInfo) { apply(info, entered: true) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        apply(info, entered: false)
        return DropProposal(operation: dragging != nil ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        if case .groupHeader(let id) = target, dropIntoGroup == id { dropIntoGroup = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropIntoGroup = nil
        if dragging != nil {
            dragging = nil
            return true
        }
        guard let provider = info.itemProviders(for: [UTType.fileURL]).first else { return false }
        FileDrop.loadURL(provider, onFile)
        return true
    }

    private func apply(_ info: DropInfo, entered: Bool) {
        guard let dragging else { return }
        MainActor.assumeIsolated {
            withAnimation(.easeInOut(duration: 0.15)) {
                do { try move(dragging, info: info, entered: entered) } catch { model.banner = error.localizedDescription }
            }
        }
    }

    @MainActor private func move(_ item: DragItem, info: DropInfo, entered: Bool) throws {
        switch (item, target) {
        // Row-on-row moves happen once on entry; repeating them while hovering would oscillate.
        case (.service(let id), .service(let other, let group)) where entered && id != other:
            let index = group.map { g in model.members(of: g).firstIndex { $0.id == other } ?? 0 }
                ?? model.topIndex(of: .service(other)) ?? 0
            try model.place(id, inGroup: group, at: index)
        case (.group(let id), .service(let other, nil)) where entered:
            try model.moveGroup(id, to: model.topIndex(of: .service(other)) ?? 0)
        case (.group(let id), .groupHeader(let other)) where entered && id != other:
            try model.moveGroup(id, to: model.topIndex(of: .group(other)) ?? 0)
        // Over a group header the result depends only on the half, so re-applying is stable.
        case (.service(let id), .groupHeader(let group)):
            if info.location.y > GroupHeaderRow.height / 2 {
                dropIntoGroup = group
                if model.service(id)?.groupID != group {
                    try model.place(id, inGroup: group, at: model.members(of: group).count)
                }
            } else {
                if dropIntoGroup == group { dropIntoGroup = nil }
                guard var index = model.topIndex(of: .group(group)) else { return }
                if let current = model.topIndex(of: .service(id)), current < index { index -= 1 }
                try model.place(id, inGroup: nil, at: index)
            }
        case (.service(let id), .end) where entered:
            try model.place(id, inGroup: nil, at: model.layout.order.count)
        case (.group(let id), .end) where entered:
            try model.moveGroup(id, to: model.layout.order.count)
        default:
            break
        }
    }
}

private struct RowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct FooterView: View {
    @Binding var route: Route
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 4) {
            Button { route = .settings } label: { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
            Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.borderless)
                .padding(.leading, 8)
                .help("Help")
                .accessibilityLabel("Help")
                .popover(isPresented: $showHelp) { HelpView().frame(width: 320) }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit (⌘Q)")
                .accessibilityHint("Stops every running command and quits")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command Manager").font(.headline)
            Text("• Each command runs with /bin/zsh -lc in its working folder (home folder if empty), with the same environment (PATH) as your Terminal login shell.")
            Text("• Commands only run while Command Manager is open. Quitting stops them.")
            Text("• Turn on \"Open at login\" and \"Start when app opens\" to bring services back after a restart.")
            Text("• A crashed command is marked Failed; turn on \"Restart on exit\" to restart it automatically.")
            Text("• Logs are kept per command (10 MB × 5 files). Open the folder from Settings.")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
    }
}

/// "Open log viewer" button used on command rows and group headers.
struct LogButton: View {
    let help: String
    let label: String
    let action: () -> Void

    var body: some View {
        // Same bordered style as the start/stop button next to it.
        Button(action: action) {
            Image(systemName: "list.bullet.rectangle")
        }
        .help(help)
        .accessibilityLabel(label)
    }
}
