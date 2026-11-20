import AppKit
import Combine
import CommandManagerCore
import SwiftUI

/// Owns one independent, resizable log viewer window per command and per group. Windows outlive
/// the popover, follow renames and membership changes, and close when what they show is deleted.
@MainActor
final class LogViewerWindows: NSObject, ObservableObject, NSWindowDelegate {
    enum Target: Hashable {
        case service(UUID)
        case group(UUID)
    }

    private weak var model: AppModel?
    private var windows: [Target: NSWindow] = [:]
    private var logs: [Target: LogViewerModel] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        super.init()
        model.$services
            .combineLatest(model.$layout)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
    }

    /// Opens the viewer for one command, or brings its window to the front.
    func open(_ serviceID: UUID) { open(.service(serviceID)) }

    /// Opens one viewer with every command of the group merged in time order.
    func openGroup(_ groupID: UUID) { open(.group(groupID)) }

    func open(_ target: Target) {
        guard let model, let title = title(for: target) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let window = windows[target] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        windows[target] = window
        install(target, in: window, model: model)
        window.setContentSize(NSSize(width: 960, height: 640))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("LogViewer-\(Self.key(target))")
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ serviceID: UUID) { windows[.service(serviceID)]?.performClose(nil) }

    /// (Re)builds the viewer for `target`; used on open and when a group's members change.
    private func install(_ target: Target, in window: NSWindow, model: AppModel) {
        logs.removeValue(forKey: target)?.stop()
        let log = LogViewerModel(sources: sources(for: target, model: model), store: model.logStore)
        let root = LogViewerView(log: log, groupName: groupName(target)) { [weak window] in window?.performClose(nil) }
            .environmentObject(model)
        let size = window.contentView?.frame.size
        window.contentViewController = NSHostingController(rootView: root)
        if let size, size.width > 0 { window.setContentSize(size) }
        logs[target] = log
        log.start()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow else { return }
            for (target, open) in windows where open === window {
                logs.removeValue(forKey: target)?.stop()
                windows.removeValue(forKey: target)
            }
            // Drop the views and every loaded record with the window.
            window.contentViewController = nil
        }
    }

    // MARK: Targets

    private static func key(_ target: Target) -> String {
        switch target {
        case .service(let id): return id.uuidString
        case .group(let id): return "group-\(id.uuidString)"
        }
    }

    private func groupName(_ target: Target) -> String? {
        guard case .group(let id) = target else { return nil }
        return model?.layout.groups.first { $0.id == id }?.name
    }

    private func title(for target: Target) -> String? {
        guard let model else { return nil }
        switch target {
        case .service(let id):
            return model.service(id).map { "Log — \($0.displayName)" }
        case .group(let id):
            guard let group = model.layout.groups.first(where: { $0.id == id }) else { return nil }
            return "Log — \(group.name) (group)"
        }
    }

    private func sources(for target: Target, model: AppModel) -> [LogViewerModel.Source] {
        switch target {
        case .service(let id):
            return [LogViewerModel.Source(serviceID: id, name: model.service(id)?.displayName ?? "")]
        case .group(let id):
            return model.members(of: id).map { LogViewerModel.Source(serviceID: $0.id, name: $0.displayName) }
        }
    }

    /// Closes viewers of deleted commands/groups, follows renames and group membership.
    private func sync() {
        guard let model else { return }
        for (target, window) in windows {
            guard let title = title(for: target) else { window.close(); continue }
            if window.title != title { window.title = title }
            guard let log = logs[target] else { continue }
            let wanted = sources(for: target, model: model)
            if wanted.map(\.serviceID) != log.sources.map(\.serviceID) {
                install(target, in: window, model: model)
            } else {
                for source in wanted { log.rename(source.serviceID, to: source.name) }
            }
        }
    }
}

/// Console-style log viewer: a native one-record-per-row table above an inspector for the selected
/// record. Data lives in `LogViewerModel`; SwiftUI only draws the chrome around the table.
struct LogViewerView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var log: LogViewerModel
    /// Set for a group viewer (all its commands merged).
    var groupName: String? = nil
    let onClose: () -> Void

    @State private var confirmClear = false
    /// Height of the detail pane; dragged with the divider and remembered across windows.
    @AppStorage("logViewer.detailHeight") private var detailHeight: Double = 280

    static let minDetailHeight: Double = 140
    static let minTableHeight: Double = 140

    static func clampedDetailHeight(_ wanted: Double, total: CGFloat) -> CGFloat {
        let maxHeight = max(minDetailHeight, Double(total) - minTableHeight - SplitHandle.thickness)
        return CGFloat(min(max(wanted, minDetailHeight), maxHeight))
    }
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { proxy in
                let height = Self.clampedDetailHeight(detailHeight, total: proxy.size.height)
                VStack(spacing: 0) {
                    table.frame(maxHeight: .infinity)
                    SplitHandle(height: $detailHeight, current: height, total: proxy.size.height)
                    inspector.frame(height: height)
                }
            }
            Divider()
            statusBar
        }
        .alert("Clear log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(groupName == nil
                 ? "The log files for this command are deleted. A running command keeps logging from now on."
                 : "The log files of all \(log.sources.count) commands in this group are deleted. Running commands keep logging from now on.")
        }
        .background(
            ZStack {
                Button("Close", action: onClose).keyboardShortcut("w")
                Button("Find") {
                    // Selected log text becomes the filter, like Find in Safari or Xcode.
                    if let selected = FindSelection.selectedText(from: log.textView) { log.query = selected }
                    filterFocused = true
                }.keyboardShortcut("f")
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        )
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Source", selection: $log.filter) {
                ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .labelsHidden()
            .accessibilityLabel("Log source filter")
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundColor(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter lines containing…", text: $log.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .help("Filter lines (⌘F)")
                    .frame(minWidth: 160, maxWidth: 320)
                    .accessibilityLabel("Filter log lines")
                if !log.query.isEmpty {
                    Button { log.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Clear filter").accessibilityLabel("Clear filter")
                }
            }
            Spacer()
            Button { log.follow.toggle() } label: {
                Label(log.follow ? "Following" : "Paused", systemImage: log.follow ? "pause.fill" : "play.fill")
            }
            .help(log.follow ? "Pause: stop scrolling to new lines (scrolling up also pauses)"
                             : "Resume: jump to the newest line and keep following")
            .accessibilityLabel(log.follow ? "Following new output" : "Paused")
            .accessibilityHint(log.follow ? "Pauses automatic scrolling" : "Resumes following new output")
            Toggle("Wrap rows", isOn: $log.wrap)
                .toggleStyle(.checkbox)
                .help("Show long lines in full instead of truncating them to one line")
            Divider().frame(height: 16)
            Button { confirmClear = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Clear log").accessibilityLabel("Clear log")
                .disabled(log.totalCount == 0)
            if log.isMerged || groupName != nil {
                Button { NSWorkspace.shared.open(model.logStore.directory) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show the logs folder in Finder").accessibilityLabel("Show logs folder in Finder")
            } else {
                Button { LogFileActions.copyPath(model, log.serviceID) } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless).help("Copy log file path").accessibilityLabel("Copy log file path")
                Button { LogFileActions.reveal(model, log.serviceID) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show log file in Finder").accessibilityLabel("Show log file in Finder")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Table

    private var table: some View {
        ZStack {
            LogTableView(model: log)
            if log.loading {
                ProgressView("Loading log…")
            } else if log.visibleCount == 0 {
                Text(emptyMessage)
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private var emptyMessage: String {
        if groupName != nil, log.sources.isEmpty { return "This group has no commands." }
        if log.totalCount == 0 {
            return groupName == nil ? "No output yet. Start the command to see its log."
                                    : "No output yet. Start the group's commands to see their logs."
        }
        if log.query.trimmingCharacters(in: .whitespaces).isEmpty { return "No \(log.filter.rawValue) lines." }
        return "No lines contain “\(log.query)”."
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let row = log.selection, let detail = log.detail {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(LogTableView.Coordinator.fullTime(row)).font(.caption.monospacedDigit())
                    LogSourceLabel(source: row.source)
                    if log.isMerged {
                        Text(log.name(of: row))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Color(nsColor: LogTableView.Coordinator.streamColor(row.stream)))
                            .lineLimit(1)
                    }
                    if detail.isJSON {
                        Text("JSON")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.6)))
                            .accessibilityLabel("Formatted as JSON")
                    }
                    Spacer()
                    Button { copy(row.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy the original log line")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
                DetailTextView(text: detailText(detail), highlight: log.highlight) { [weak log] in log?.textView = $0 }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Selected log record, \(row.source.rawValue), \(LogTableView.Coordinator.fullTime(row))")
        } else {
            Text("Select a row to see the full log line.")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailText(_ detail: LogDetail) -> String {
        let body = detail.json ?? detail.original
        return detail.prefix.map { "\($0)\n\n\(body)" } ?? body
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(log.follow ? "Following new output" : "Paused — new output is loaded but not scrolled to")
            if log.loadingEarlier {
                Text("· Loading earlier lines…")
            } else if log.atMemoryLimit {
                Text("· Older lines stay in the log file")
                    .help("The viewer keeps at most \(LogViewerModel.maxRows) lines in memory")
            }
            Spacer()
            if log.canLoadEarlier && !log.loadingEarlier {
                Button("Load earlier") { log.loadEarlier() }
                    .buttonStyle(.link)
                    .help("Load older lines (also happens when you scroll to the top)")
            }
            Text(log.visibleCount == log.totalCount ? "\(log.totalCount) lines" : "\(log.visibleCount) of \(log.totalCount) lines")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Read-only, selectable, always-wrapping text: NSTextView lays out large records lazily.
struct DetailTextView: NSViewRepresentable {
    let text: String
    var highlight = ""
    /// Receives the text view, so Cmd+F can use its selection.
    var register: ((NSTextView) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.textColor = .labelColor
        view.setAccessibilityLabel("Log record text")
        view.delegate = context.coordinator
        register?(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let textChanged = view.string != text
        guard textChanged || context.coordinator.highlight != highlight else { return }
        context.coordinator.highlight = highlight
        if textChanged { view.string = text }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: whole)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        LogHighlightStyle.apply(highlight, to: storage, in: NSRange(location: 0, length: 0), text: text)
        storage.endEditing()
        if let first = LogHighlight.ranges(of: highlight, in: text).first {
            view.scrollRangeToVisible(first)
        } else if textChanged {
            view.scrollToBeginningOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var highlight = ""

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            LogTextMenu.addItems(to: menu, for: view)
        }
    }
}

/// Source shown as text plus icon, so it does not rely on color alone.
struct LogSourceLabel: View {
    let source: LogSource

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon).imageScale(.small).accessibilityHidden(true)
            Text(source.rawValue)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(color)
        .accessibilityLabel(name)
    }

    private var icon: String {
        switch source {
        case .stdout: return "text.alignleft"
        case .stderr: return "exclamationmark.triangle.fill"
        case .system: return "gearshape"
        }
    }

    private var color: Color {
        switch source {
        case .stdout: return .primary
        case .stderr: return .red
        case .system: return .secondary
        }
    }

    private var name: String {
        switch source {
        case .stdout: return "standard output"
        case .stderr: return "standard error"
        case .system: return "Command Manager event"
        }
    }
}

/// Log file utilities shared by the popover log panel and the viewer window.
@MainActor
enum LogFileActions {
    static func copyPath(_ model: AppModel, _ serviceID: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.logStore.logFileURL(for: serviceID).path, forType: .string)
    }

    static func reveal(_ model: AppModel, _ serviceID: UUID) {
        let url = model.logStore.logFileURL(for: serviceID)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(model.logStore.directory)
        }
    }
}

/// Horizontal divider between the table and the detail pane: drag to resize, double-click resets.
struct SplitHandle: View {
    static let thickness: Double = 7

    @Binding var height: Double
    let current: CGFloat
    let total: CGFloat
    @State private var start: Double?

    var body: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(height: Self.thickness)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = start ?? Double(current)
                    if start == nil { start = base }
                    let wanted = base - Double(value.translation.height)
                    height = Double(LogViewerView.clampedDetailHeight(wanted, total: total))
                }
                .onEnded { _ in start = nil }
        )
        .onTapGesture(count: 2) { height = 280 }
        .accessibilityElement()
        .accessibilityLabel("Resize detail pane")
        .accessibilityValue("\(Int(current)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: height = Double(LogViewerView.clampedDetailHeight(Double(current) + 40, total: total))
            case .decrement: height = Double(LogViewerView.clampedDetailHeight(Double(current) - 40, total: total))
            @unknown default: break
            }
        }
    }
}

/// Text the user has selected in a log text view (the detail pane or the popover log), used to
/// pre-fill the filter on Cmd+F.
@MainActor
enum FindSelection {
    /// Filter matches one line at a time, so a multi-line selection contributes its first line.
    static let maxLength = 200

    /// The selection in `view`, if it is focused in its window and has selected text.
    static func selectedText(from view: NSTextView?) -> String? {
        guard let view, view.window?.firstResponder === view else { return nil }
        let range = view.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let selected = (view.string as NSString).substring(with: range)
        return firstLine(of: selected)
    }

    static func firstLine(of text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return String(line.prefix(maxLength))
    }
}

/// Context-menu items for selected log text: unescape escaped JSON and copy it.
@MainActor
final class LogTextMenu: NSObject {
    static let shared = LogTextMenu()

    /// Adds the unescape items (for a non-empty selection) above the standard text menu.
    static func addItems(to menu: NSMenu, for view: NSTextView) -> NSMenu {
        let range = view.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return menu }
        let selected = (view.string as NSString).substring(with: range)
        let canUnescape = JSONUnescape.unescape(selected) != nil
        let items = [
            item("Unescape JSON & Copy", #selector(copyUnescaped(_:)), selected, enabled: canUnescape),
            item("Unescape JSON & Copy (Formatted)", #selector(copyUnescapedFormatted(_:)), selected, enabled: canUnescape),
            NSMenuItem.separator(),
        ]
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ text: String, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = shared
        item.representedObject = text
        item.isEnabled = enabled
        if !enabled { item.toolTip = "The selection has no escaped JSON or escape sequences" }
        return item
    }

    @objc private func copyUnescaped(_ sender: NSMenuItem) {
        copy((sender.representedObject as? String).flatMap(JSONUnescape.unescape))
    }

    @objc private func copyUnescapedFormatted(_ sender: NSMenuItem) {
        copy((sender.representedObject as? String).flatMap(JSONUnescape.unescapeFormatted))
    }

    private func copy(_ text: String?) {
        guard let text else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
