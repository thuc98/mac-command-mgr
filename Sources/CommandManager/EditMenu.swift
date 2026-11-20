import AppKit

/// A status-bar (accessory) app has no main menu, and AppKit routes Cmd+C/V/X/A/Z through the
/// main menu's key equivalents — without one, copy/paste does nothing in text fields and logs.
/// The menu is never visible (no menu bar for accessory apps) but its shortcuts work.
/// Ctrl+C/V/X/A/Z (and Ctrl+Shift+Z / Ctrl+Y) are mapped to the same actions for users used to
/// Windows/Linux shortcuts; a Ctrl shortcut nothing in the UI can handle passes through unchanged.
@MainActor
enum EditMenu {
    private static var monitor: Any?

    static func install() {
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = controlShortcut(for: event) else { return event }
            // nil target = current first responder chain (text field, text editor, selectable log text).
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }

    static func controlShortcut(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == .control || flags == [.control, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let shifted = flags.contains(.shift)
        switch (key, shifted) {
        case ("c", false): return #selector(NSText.copy(_:))
        case ("v", false): return #selector(NSText.paste(_:))
        case ("x", false): return #selector(NSText.cut(_:))
        case ("a", false): return #selector(NSText.selectAll(_:))
        case ("z", false): return Selector(("undo:"))
        case ("z", true), ("y", false): return Selector(("redo:"))
        default: return nil
        }
    }
}
