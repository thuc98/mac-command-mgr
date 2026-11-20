import AppKit
import CommandManagerCore
import SwiftUI

enum LogFilter: String, CaseIterable, Identifiable {
    case all = "All", stdout = "stdout", stderr = "stderr"
    var id: String { rawValue }

    func includes(_ line: LogLine) -> Bool {
        switch self {
        case .all: return true
        case .stdout: return line.source == .stdout
        case .stderr: return line.source == .stderr
        }
    }
}

struct ServiceDetailView: View {
    @EnvironmentObject var model: AppModel
    let serviceID: UUID
    @Binding var route: Route

    @State private var confirmForce = false
    @State private var confirmDelete = false

    var body: some View {
        if let service = model.service(serviceID) {
            content(service, record: model.record(serviceID))
        }
    }

    private func content(_ service: ServiceDefinition, record: RuntimeRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { route = .list } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Edit") { route = .edit(serviceID) }
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .disabled(record.state.isActive)
                    .help(record.state.isActive ? "Stop the command before deleting it" : "Delete command")
                    .accessibilityLabel("Delete \(service.displayName)")
            }
            .padding(12)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(service.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    StatusBadge(state: record.state)
                }
                info(service, record)
                actions(service, record)
                HStack(spacing: 16) {
                    Toggle("Enabled", isOn: Binding(
                        get: { service.isEnabled },
                        set: { value in run { try model.setEnabled(value, for: serviceID) } }
                    ))
                    .accessibilityHint("Disabled commands cannot be started")
                    Toggle("Start when app opens", isOn: Binding(
                        get: { service.autoStart },
                        set: { value in run { try model.setAutoStart(value, for: serviceID) } }
                    ))
                    .help("Command Manager starts this command each time it opens, including at login. It is not registered as a system service.")
                    .accessibilityHint("Starts this command when Command Manager opens at login")
                    Toggle("Restart on exit", isOn: Binding(
                        get: { service.restartOnExit },
                        set: { value in run { try model.setRestartOnExit(value, for: serviceID) } }
                    ))
                    .help("When the command exits or crashes on its own, start it again after 1 s, then 2 s, 4 s … up to 1 min between tries. A run of 1 min or more resets the wait. Stop cancels it.")
                    .accessibilityHint("Restarts the command automatically with increasing delays")
                }
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 12)

            Divider().padding(.top, 8)
            LogPanel(serviceID: serviceID, store: model.logStore)
        }
        .alert("Force stop \(service.displayName)?", isPresented: $confirmForce) {
            Button("Force Stop", role: .destructive) { model.forceStop(serviceID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The command did not stop in time. SIGKILL will end its process group immediately; unsaved work in it may be lost.")
        }
        .alert("Delete \(service.displayName)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                run {
                    try model.delete(serviceID)
                    route = .list
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The command is removed and will no longer start when the app opens. Its working folder and log files are not deleted.\(record.state == .unknown ? " A process from a previous session (PID \(record.pid.map { String($0) } ?? "?")) may still be running; Command Manager will not stop it." : "")")
        }
    }

    private func info(_ service: ServiceDefinition, _ record: RuntimeRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Command", service.command, mono: true)
            row("Folder", service.workingDirectory ?? "~ (home)", mono: true)
            if let pid = record.pid { row("PID", String(pid), mono: true) }
            if let started = record.startedAt, record.state.isActive {
                row("Started", Formatters.time.string(from: started))
            }
            if let ended = record.endedAt, !record.state.isActive {
                row("Ended", Formatters.time.string(from: ended))
            }
            if let code = record.exitCode { row("Exit code", String(code), mono: true) }
            if let next = record.nextRestartAt {
                HStack(alignment: .firstTextBaseline) {
                    Text("Restart").font(.caption).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
                    (Text("in ") + Text(next, style: .timer) + Text(" (attempt \(record.restartAttempt))"))
                        .font(.caption.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
            row("Changed", Formatters.time.string(from: record.lastChange))
            if let error = record.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange).accessibilityHidden(true)
                    Text(error).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Last error: \(error)")
            }
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ service: ServiceDefinition, _ record: RuntimeRecord) -> some View {
        HStack {
            Button { model.start(serviceID) } label: { Label("Start", systemImage: "play.fill") }
                .disabled(!service.isEnabled || record.state.isActive || record.state == .unknown)
                .help(service.isEnabled ? "Start" : "Enable this command to start it")
            Button { model.stop(serviceID) } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(record.state != .running && record.nextRestartAt == nil)
                .help(record.nextRestartAt != nil ? "Cancel the automatic restart" : "Stop")
            Button { model.restart(serviceID) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .disabled(record.state != .running || !service.isEnabled)
            if record.state == .stopping && record.stopTimedOut {
                Button(role: .destructive) { confirmForce = true } label: { Label("Force Stop", systemImage: "bolt.slash") }
            }
            if record.state == .unknown || record.state == .failed || record.state == .exited {
                Button("Clear status") { model.clearStatus(serviceID) }
                    .help("Mark as stopped. No signal is sent.")
            }
        }
        .controlSize(.small)
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { model.banner = error.localizedDescription }
    }
}

struct LogPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var popoverController: PopoverController
    @EnvironmentObject var logViewers: LogViewerWindows
    let serviceID: UUID
    /// Incremental reader shared with the log window's design; a small budget for the popover.
    @StateObject private var log: LogViewerModel
    @State private var confirmClear = false
    @FocusState private var filterFocused: Bool

    /// Records kept for the compact panel; the full history is one click away in the window.
    static let maxRows = 3_000

    init(serviceID: UUID, store: LogStore) {
        self.serviceID = serviceID
        _log = StateObject(wrappedValue: LogViewerModel(
            serviceID: serviceID, store: store,
            maxRows: Self.maxRows, maxTextBytes: 4 * 1024 * 1024, initialBytes: 128 * 1024))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                Picker("Source", selection: $log.filter) {
                    ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .labelsHidden()
                .accessibilityLabel("Log source filter")
                Spacer()
                Button { logViewers.open(serviceID) } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open log viewer")
                .help("Open this log in a resizable window with a table, pause/follow and line details")
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Clear log").accessibilityLabel("Clear log")
                    .disabled(log.totalCount == 0)
                Button { LogFileActions.copyPath(model, serviceID) } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless).help("Copy log file path").accessibilityLabel("Copy log file path")
                Button { LogFileActions.reveal(model, serviceID) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show log file in Finder").accessibilityLabel("Show log file in Finder")
            }
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundColor(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter lines containing…", text: $log.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .help("Filter lines (⌘F)")
                    .accessibilityLabel("Filter log lines")
                if !log.query.isEmpty {
                    Button { log.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Clear filter").accessibilityLabel("Clear filter")
                }
            }
            ZStack {
                LogTextView(model: log)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                if log.loading {
                    ProgressView("Loading log…")
                } else if log.visibleCount == 0 {
                    Text(emptyMessage)
                        .foregroundColor(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background(
            Button("Find") {
                    // Selected log text becomes the filter, like Find in Safari or Xcode.
                    if let selected = FindSelection.selectedText(from: log.textView) { log.query = selected }
                    filterFocused = true
                }.keyboardShortcut("f")
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        )
        .alert("Clear log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The log files for this command are deleted. A running command keeps logging from now on.")
        }
        // Read only while the popover is on screen.
        .onAppear { if popoverController.isShown { log.start() } }
        .onDisappear { log.stop() }
        .onChange(of: popoverController.isShown) { shown in if shown { log.start() } else { log.stop() } }
    }

    private var emptyMessage: String {
        if log.totalCount == 0 { return "No output yet. Start the command to see its log." }
        if log.query.trimmingCharacters(in: .whitespaces).isEmpty { return "No \(log.filter.rawValue) lines." }
        return "No lines contain “\(log.query)”."
    }
}

/// Plain-text log for the popover: an NSTextView that appends new records instead of re-laying
/// out the whole log, keeps at most `maxLines` on screen, and sticks to the end unless the user
/// scrolled up.
struct LogTextView: NSViewRepresentable {
    @ObservedObject var model: LogViewerModel
    static let maxLines = 1_500

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = true
            view.backgroundColor = .textBackgroundColor
            view.textContainerInset = NSSize(width: 4, height: 6)
            view.layoutManager?.allowsNonContiguousLayout = true
            view.setAccessibilityLabel("Log output")
            view.delegate = context.coordinator
        }
        context.coordinator.attach(scroll)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: LogViewerModel
        private weak var scroll: NSScrollView?
        /// UTF-16 length of each line on screen (newline included), oldest first.
        private var lengths: [Int] = []

        private static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        private static let timeAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        private static let attributes: [LogSource: [NSAttributedString.Key: Any]] = [
            .stdout: [.font: font, .foregroundColor: NSColor.labelColor],
            .stderr: [.font: font, .foregroundColor: NSColor.systemRed],
            .system: [.font: font, .foregroundColor: NSColor.secondaryLabelColor],
        ]

        init(model: LogViewerModel) { self.model = model }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            LogTextMenu.addItems(to: menu, for: view)
        }

        func attach(_ scroll: NSScrollView) {
            self.scroll = scroll
            model.textView = scroll.documentView as? NSTextView
            model.onChange = { [weak self] change in self?.apply(change) }
            rebuild()
        }

        func detach() {
            model.onChange = nil
        }

        private var textView: NSTextView? { scroll?.documentView as? NSTextView }

        private var isAtEnd: Bool {
            guard let scroll, let document = scroll.documentView else { return true }
            return scroll.contentView.bounds.maxY >= document.frame.height - 24
        }

        private func apply(_ change: LogViewerModel.TableChange) {
            switch change {
            case .appended(let count):
                let end = model.rowCount
                append(rows: (end - count)..<end)
            case .reload, .prepended, .droppedFront:
                // Rare (reset, filter change, memory trim): rebuild from the newest records.
                rebuild()
            }
        }

        private func rebuild() {
            guard let storage = textView?.textStorage else { return }
            lengths.removeAll(keepingCapacity: true)
            let end = model.rowCount
            let text = render((max(0, end - LogTextView.maxLines))..<end)
            storage.setAttributedString(text)
            scrollToEnd()
        }

        private func append(rows: Range<Int>) {
            guard let storage = textView?.textStorage, !rows.isEmpty else { return }
            let follow = isAtEnd
            storage.beginEditing()
            storage.append(render(rows.suffix(LogTextView.maxLines).startIndex..<rows.upperBound))
            let excess = lengths.count - LogTextView.maxLines
            if excess > 0 {
                let cut = lengths.prefix(excess).reduce(0, +)
                storage.deleteCharacters(in: NSRange(location: 0, length: min(cut, storage.length)))
                lengths.removeFirst(excess)
            }
            storage.endEditing()
            if follow { scrollToEnd() }
        }

        private func render(_ rows: Range<Int>) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for index in rows {
                guard let row = model.row(at: index) else { continue }
                let time = LogTableView.Coordinator.time(row) + " "
                let tag = "\(row.source.rawValue) "
                let body = "\(tag)\(row.text)\n"
                out.append(NSAttributedString(string: time, attributes: Self.timeAttributes))
                let start = out.length + (tag as NSString).length
                out.append(NSAttributedString(string: body, attributes: Self.attributes[row.source] ?? [:]))
                LogHighlightStyle.apply(model.highlight, to: out, in: NSRange(location: start, length: 0), text: row.text)
                lengths.append((time as NSString).length + (body as NSString).length)
            }
            return out
        }

        private func scrollToEnd() {
            textView?.scrollToEndOfDocument(nil)
        }
    }
}
