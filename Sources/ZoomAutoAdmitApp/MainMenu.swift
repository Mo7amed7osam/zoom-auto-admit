import AppKit

/// The application's main menu.
///
/// This is a menu-bar-only app (`LSUIElement`), so this menu is never displayed.
/// It still has to exist: AppKit delivers ⌘X / ⌘C / ⌘V and friends to text
/// fields by matching them against the main menu's key equivalents, so without
/// an Edit menu, paste simply does nothing in the app's windows.
///
/// Every item targets `nil`, which sends the action down the responder chain to
/// whichever text field is focused.
enum MainMenu {
    static func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private static func applicationMenuItem() -> NSMenuItem {
        let name = "Zoom Auto Admit"
        let menu = NSMenu(title: name)
        menu.addItem(
            withTitle: "Hide \(name)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")

        add(to: menu, "Undo", #selector(UndoActions.undo(_:)), "z")
        add(to: menu, "Redo", #selector(UndoActions.redo(_:)), "Z")
        menu.addItem(.separator())
        add(to: menu, "Cut", #selector(NSText.cut(_:)), "x")
        add(to: menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(to: menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(
            to: menu,
            "Paste and Match Style",
            #selector(NSTextView.pasteAsPlainText(_:)),
            "V",
            modifiers: [.command, .option, .shift]
        )
        add(to: menu, "Delete", #selector(NSText.delete(_:)), "")
        add(to: menu, "Select All", #selector(NSText.selectAll(_:)), "a")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        add(to: menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(to: menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func add(
        to menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        // nil target: the action travels the responder chain to the focused field.
        item.target = nil
        menu.addItem(item)
    }
}

/// Undo and redo are declared on `UndoManager`'s client rather than on `NSText`,
/// so the selectors are named here for the responder chain to resolve.
@objc private protocol UndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}
