import AppKit
import Combine
import CommandManagerCore
import SwiftUI

/// Lets SwiftUI views keep the popover open while a system panel (folder picker) is shown.
@MainActor
final class PopoverController: NSObject, ObservableObject, NSPopoverDelegate {
    weak var popover: NSPopover?
    @Published private(set) var isShown = false

    nonisolated func popoverDidShow(_ notification: Notification) {
        MainActor.assumeIsolated {
            isShown = true
            // Open instantly, but animate size changes between screens (list ↔ detail ↔ form).
            popover?.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { isShown = false }
    }

    func withPinnedPopover(_ body: (@escaping () -> Void) -> Void) {
        let previous = popover?.behavior ?? .transient
        popover?.behavior = .applicationDefined
        body { [weak self] in self?.popover?.behavior = previous }
    }

    func close() { popover?.performClose(nil) }

    /// Follows the SwiftUI content height (the list view grows and shrinks with its rows).
    func setContentHeight(_ height: CGFloat) {
        guard let popover, height > 0 else { return }
        let size = NSSize(width: popover.contentSize.width, height: ceil(height))
        if popover.contentSize != size { popover.contentSize = size }
    }

    /// Set when a file is dropped (on the popover or the status icon); RootView opens the add form.
    @Published var pendingDraft: ServiceDraft?
    /// Shows the popover (used after a drop on the status icon).
    var show: (() -> Void)?

    func handleDrop(_ url: URL, model: AppModel) {
        guard let draft = LaunchInference.draft(for: url, existing: model.services) else {
            model.banner = "Cannot add \(url.lastPathComponent): the file no longer exists."
            return
        }
        show?()
        pendingDraft = draft
    }
}

/// Transparent layer over the status-bar button that accepts dropped files and passes clicks through.
final class StatusItemDropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { (superview as? NSButton)?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { (superview as? NSButton)?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(sender) else { return false }
        onDrop?(url)
        return true
    }

    private func fileURL(_ info: NSDraggingInfo) -> URL? {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var model: AppModel!
    private let popoverController = PopoverController()
    private var cancellables: Set<AnyCancellable> = []
    private var controlServer: ControlServer?
    private var logViewers: LogViewerWindows!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceController.apply(.stored())
        model = AppModel(paths: .standard(), loginItem: LoginItemFactory.make())
        model.supervisor.onStateChange = { [weak self] id, state in
            self?.announce(id: id, state: state)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.imagePosition = .imageLeading
            let dropView = StatusItemDropView(frame: button.bounds)
            dropView.onDrop = { [weak self] url in
                guard let self else { return }
                self.popoverController.handleDrop(url, model: self.model)
            }
            button.addSubview(dropView)
        }
        popoverController.show = { [weak self] in self?.showPopover() }
        logViewers = LogViewerWindows(model: model)

        popover.behavior = .transient
        // Appear instantly (the open animation looked jerky); resizes animate once shown.
        popover.animates = false
        popover.contentSize = NSSize(width: 440, height: 560)
        popoverController.popover = popover
        popover.delegate = popoverController
        popover.contentViewController = NSHostingController(
            rootView: RootView()
                // Pinned to the top so content does not drift while the popover resizes.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environmentObject(model)
                .environmentObject(popoverController)
                .environmentObject(logViewers)
        )

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        EditMenu.install()
        model.onEnvironmentReady = { [weak self] environment in self?.installCommandLineTool(path: environment["PATH"]) }
        model.launch(shellEnvironment: { LoginShellEnvironment.capture() })
        startControlServer()
        refreshStatusItem()
    }

    /// Links the bundled `cmgr` into a folder on the user's PATH, so installing the app is enough.
    private func installCommandLineTool(path: String?) {
        guard let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("cmgr").path,
              FileManager.default.fileExists(atPath: binary), // `swift run` without a bundle
              ProcessInfo.processInfo.environment["CMGR_HOME"] == nil // test/dev data folder: leave PATH alone
        else { return }
        switch CLIInstaller.install(binary: binary, pathEnvironment: path) {
        case .installed, .unchanged:
            break
        case .notOnPath(let link):
            model.banner = "The cmgr command was installed at \(link), which is not on your PATH. Add  export PATH=\"$HOME/.local/bin:$PATH\"  to ~/.zshrc."
        case .failed(let reason):
            model.banner = "Could not install the cmgr command: \(reason)"
        }
    }

    /// Local socket used by the `cmgr` CLI and its MCP server (AI agents).
    private func startControlServer() {
        let service = ControlService(model: model, isLive: true)
        let server = ControlServer(socketPath: model.paths.controlSocket.path) { op, args in
            service.respond(op: op, args: args)
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            model.banner = "cmgr / AI control is unavailable: \(error.localizedDescription)"
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controlServer?.stop()
        guard let model else { return .terminateNow }
        // Commands do not outlive the app: SIGTERM, short grace period, then SIGKILL.
        model.stopAllForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.refreshLoginItemStatus()
        NSApp.activate(ignoringOtherApps: true)
        popover.animates = false
        // Size to the content before showing, so it does not open at a stale height and then jump.
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let fitting = view.fittingSize
            if fitting.height > 0 { popover.contentSize = NSSize(width: popover.contentSize.width, height: ceil(fitting.height)) }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let running = model.runningCount
        let failed = model.failedCount
        let description = "Command Manager, \(running) running, \(failed) failed"
        let image: NSImage?
        if failed > 0 {
            image = StatusIcon.failed(running: running > 0, accessibilityDescription: description)
        } else {
            image = NSImage(systemSymbolName: running > 0 ? "terminal.fill" : "terminal",
                            accessibilityDescription: description)
            image?.isTemplate = true
        }
        button.image = image
        // Icon only; counts are in the popover header and the tooltip.
        button.title = ""
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    private func announce(id: UUID, state: RuntimeState) {
        guard let name = model.service(id)?.displayName else { return }
        let element: Any = popover.contentViewController?.view.window ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(name): \(state.label)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

/// Menu bar icon while a command has failed: the usual terminal glyph with a red "!" badge, so the
/// app stays recognizable and the failure stands out. Drawn on demand, so the glyph follows the
/// menu bar's light/dark appearance like a template image would.
enum StatusIcon {
    static func failed(running: Bool, accessibilityDescription: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: running ? "terminal.fill" : "terminal",
                                 accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let badge: CGFloat = 9
        let size = NSSize(width: base.size.width + 3, height: base.size.height + 3)
        let image = NSImage(size: size, flipped: false) { rect in
            // Glyph tinted with the current appearance's label color.
            let glyph = NSImage(size: base.size, flipped: false) { glyphRect in
                base.draw(in: glyphRect)
                NSColor.labelColor.withAlphaComponent(1).set()
                glyphRect.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: NSRect(origin: .zero, size: base.size))
            let dot = NSRect(x: rect.maxX - badge, y: rect.maxY - badge, width: badge, height: badge)
            // Cut a gap around the badge so it reads on any menu bar.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            let mark = NSAttributedString(string: "!", attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .heavy), .foregroundColor: NSColor.white,
            ])
            let markSize = mark.size()
            mark.draw(at: NSPoint(x: dot.midX - markSize.width / 2, y: dot.midY - markSize.height / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
