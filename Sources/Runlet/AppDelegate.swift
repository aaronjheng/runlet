import AppKit
import SwiftUI

@MainActor
final class WindowDelegateManager {
    private var delegates: [ObjectIdentifier: WindowDelegate] = [:]

    func setDelegate(_ delegate: WindowDelegate, for window: NSWindow) {
        let id = ObjectIdentifier(window)
        delegates[id] = delegate
    }

    func removeDelegate(for window: NSWindow) {
        let id = ObjectIdentifier(window)
        delegates.removeValue(forKey: id)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let tabManager = TabManager()
    private var stateToWindow: [UUID: NSWindow] = [:]
    let tabShortcutLimit = 9
    private var tabRefreshScheduled = false
    private var settingsWindow: NSWindow?
    private var settingsToolbarController: SettingsToolbarController?
    private let delegateManager = WindowDelegateManager()

    private var currentAppearance: AppAppearance {
        AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        currentAppearance.apply()
        buildMenuBar()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidUpdate(_:)),
            name: NSApplication.didUpdateNotification,
            object: nil
        )
        sweepStaleTemporaryKeychains()
        openNewTab()
        if let window = NSApp.keyWindow {
            currentAppearance.applyToWindow(window)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SettingsStore.shared.settings.confirmBeforeQuit, !confirmQuit() {
            return .terminateCancel
        }
        // Flush async state (SSH socket dir in /tmp) before quitting. The wait
        // is capped so logout/shutdown can never hang on a stuck tunnel; crash
        // or `kill -9` exits skip this and rely on the next launch's sweep.
        Task {
            try? await withTimeout(3, context: "SSH pool shutdown") {
                await SystemSSHConnectionPool.shared.shutdownAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Modal quit confirmation. Returns true when the user chose to quit.
    /// Opt-out lives only in Settings → Application, so the alert keeps the
    /// system layout (a suppression checkbox forces the legacy style).
    private func confirmQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit Runlet"
        alert.informativeText = "Open connections will be closed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func openNewTab() {
        let state = tabManager.createTab()
        createWindow(for: state, tabbed: true)
    }

    @objc func openNewWindow() {
        let state = tabManager.createTab()
        createWindow(for: state, tabbed: false)
    }

    @objc func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    @objc func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let navigation = SettingsNavigationState()
        let split = SettingsSplitViewController(
            sidebar: SettingsSidebarView().environment(navigation),
            detail: SettingsView().environment(navigation)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 780, height: 520)
        window.setContentSize(NSSize(width: 780, height: 520))
        let toolbarController = SettingsToolbarController(navigation: navigation)
        toolbarController.install(in: window)
        settingsToolbarController = toolbarController
        window.center()
        currentAppearance.applyToWindow(window)
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        guard let appearance = AppAppearance(rawValue: sender.tag) else { return }
        SettingsStore.shared.settings.appearance = appearance.rawValue
        SettingsStore.shared.save()
        appearance.apply()
        for window in NSApp.windows {
            appearance.applyToWindow(window)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setAppearance(_:)) {
            menuItem.state = menuItem.tag == SettingsStore.shared.settings.appearance ? .on : .off
        }
        return true
    }
    @objc func newWindowForTab(_ sender: Any?) {
        openNewTab()
    }

    @objc func selectNextTab() {
        guard let tabGroup = NSApp.keyWindow?.tabGroup,
            let current = NSApp.keyWindow,
            let index = tabGroup.windows.firstIndex(of: current)
        else { return }
        let next = tabGroup.windows[(index + 1) % tabGroup.windows.count]
        next.makeKeyAndOrderFront(nil)
    }

    @objc func selectPreviousTab() {
        guard let tabGroup = NSApp.keyWindow?.tabGroup,
            let current = NSApp.keyWindow,
            let index = tabGroup.windows.firstIndex(of: current)
        else { return }
        let prev = tabGroup.windows[(index - 1 + tabGroup.windows.count) % tabGroup.windows.count]
        prev.makeKeyAndOrderFront(nil)
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        selectTab(at: sender.tag - 1)
    }

    private func createWindow(for state: TabState, tabbed: Bool) {
        let contentView = TabContentView()
            .environment(state)
            .environment(ConnectionStore.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Runlet"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: contentView)
        window.collectionBehavior.insert(NSWindow.CollectionBehavior.fullScreenPrimary)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "Runlet"

        if tabbed, let existingWindow = NSApp.keyWindow {
            existingWindow.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }

        currentAppearance.applyToWindow(window)
        stateToWindow[state.id] = window
        requestTabChromeRefresh()

        let delegate = WindowDelegate { [weak self, weak window] in
            // Drop the manager's strong reference (and the window's) to this
            // delegate synchronously while the window is still alive, otherwise
            // `delegateManager.delegates` accumulates every closed tab's delegate
            // (and its strongly-captured TabState) for the app's lifetime.
            if let self, let window {
                self.delegateManager.removeDelegate(for: window)
                window.delegate = nil
            }
            Task { @MainActor in
                guard let self else { return }
                self.tabManager.closeTab(state)
                self.stateToWindow.removeValue(forKey: state.id)
                self.requestTabChromeRefresh()
            }
        }
        window.delegate = delegate
        delegateManager.setDelegate(delegate, for: window)
    }

    @objc private func handleApplicationDidUpdate(_ notification: Notification) {
        requestTabChromeRefresh()
    }

    private func requestTabChromeRefresh() {
        guard !tabRefreshScheduled else { return }
        tabRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.tabRefreshScheduled = false
            self.refreshTabChrome()
        }
    }

    private func refreshTabChrome() {
        var refreshedGroups = Set<ObjectIdentifier>()

        for window in stateToWindow.values {
            if let tabGroup = window.tabGroup {
                let groupID = ObjectIdentifier(tabGroup)
                guard refreshedGroups.insert(groupID).inserted else { continue }
                syncTabAccessories(in: tabGroup.windows)
            } else {
                syncTabAccessories(in: [window])
            }
        }
    }

    private func selectTab(at index: Int) {
        guard index >= 0 else { return }

        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        if let tabGroup = targetWindow?.tabGroup, index < tabGroup.windows.count {
            tabGroup.windows[index].makeKeyAndOrderFront(nil)
        } else if index == 0 {
            targetWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func syncTabAccessories(in windows: [NSWindow]) {
        for (index, window) in windows.enumerated() {
            if windows.count > 1, index < tabShortcutLimit {
                window.tab.accessoryView = makeTabAccessoryView(text: "\u{2318}\(index + 1)")
            } else {
                window.tab.accessoryView = nil
            }
        }
    }

    private func makeTabAccessoryView(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 34),
            container.heightAnchor.constraint(equalToConstant: 16),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }
}

class WindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
