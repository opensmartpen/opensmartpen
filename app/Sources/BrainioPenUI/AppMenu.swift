import AppKit

/// The menu bar a menubar-only app still needs.
///
/// Brainio Pen is an accessory app: no Dock icon, no menu bar on screen. That is the look we want,
/// and it comes with a trap. On macOS the standard editing keys are not built into a text field —
/// ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z are key equivalents of items in the Edit menu, and an app with no menu
/// has none of them. So the settings fields could be typed into but not copied out of, and a key
/// pasted from a password manager could not be pasted at all.
///
/// Nothing here is shown to anybody. It exists so the keys work in the windows this app does open.
public enum AppMenu {
    /// Build it once, at launch. Safe to call again; the menu is simply replaced.
    public static func install(into app: NSApplication = .shared) {
        let main = NSMenu()

        // The first menu is the application menu. It is never drawn for an accessory app, but the
        // menu bar expects it to be there, and Services and the standard shortcuts hang off it.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = editMenu()
        main.addItem(editItem)

        // ⌘W closes the window in front. Without it, a settings window opened from the panel can
        // only be closed with the mouse.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        app.mainMenu = main
    }

    /// The standard editing items, each sent to whatever has the keyboard — which is the text field
    /// the person is typing in.
    public static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        add(menu, "Undo", #selector(UndoActionResponder.undo(_:)), "z")
        add(menu, "Redo", #selector(UndoActionResponder.redo(_:)), "Z")
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        return menu
    }

    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // No target: the action travels up the responder chain to the field with the keyboard.
        item.target = nil
        menu.addItem(item)
    }
}

/// `undo:` and `redo:` are sent to the first responder's undo manager and belong to no class we can
/// name, so this declares them to get a selector.
@objc private protocol UndoActionResponder {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}
