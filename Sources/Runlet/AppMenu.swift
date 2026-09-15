import AppKit

extension AppDelegate {
    func buildMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Runlet",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Runlet",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(openNewWindow), keyEquivalent: "n")
        newWindowItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(newWindowItem)
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(openNewTab), keyEquivalent: "t")
        newTabItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(newTabItem)
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeTabItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(closeTabItem)
        fileMenuItem.submenu = fileMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        let nextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(selectNextTab), keyEquivalent: "\u{2192}")
        nextTabItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(nextTabItem)
        let prevTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(selectPreviousTab), keyEquivalent: "\u{2190}")
        prevTabItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(prevTabItem)
        windowMenu.addItem(.separator())
        for index in 1...tabShortcutLimit {
            let item = NSMenuItem(
                title: "Select Tab \(index)",
                action: #selector(selectTabByNumber(_:)),
                keyEquivalent: "\(index)"
            )
            item.tag = index
            item.keyEquivalentModifierMask = [.command]
            windowMenu.addItem(item)
        }
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let fsItem = NSMenuItem(title: "Enter Full Screen", action: #selector(toggleFullScreen), keyEquivalent: "f")
        fsItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fsItem)
        viewMenu.addItem(.separator())
        let currentAppearance = AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system
        for appearance in AppAppearance.allCases {
            let item = NSMenuItem(
                title: appearance.name,
                action: #selector(setAppearance(_:)),
                keyEquivalent: ""
            )
            item.tag = appearance.rawValue
            item.target = self
            item.state = currentAppearance == appearance ? .on : .off
            viewMenu.addItem(item)
        }
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }
}
