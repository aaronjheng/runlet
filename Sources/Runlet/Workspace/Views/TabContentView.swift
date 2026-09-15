import AppKit
import SwiftUI

// MARK: - Tab Content View (per-tab)

struct TabContentView: View {
    @Environment(TabState.self) private var tab

    var body: some View {
        HSplitView {
            Group {
                if tab.activeSession?.isConnected == true {
                    WorkspaceSidebarView()
                        .transition(.opacity)
                } else {
                    ConnectionHubSidebarView()
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 220, maxWidth: 280)

            Group {
                if tab.activeSession?.isConnected == true {
                    WorkspaceView()
                        .transition(.opacity)
                } else {
                    ConnectionHubView()
                        .transition(.opacity)
                }
            }
        }
        .animation(.default, value: tab.activeSession?.isConnected)
        .background(WindowTitleUpdater())
    }
}

// MARK: - Window Title Updater

struct WindowTitleUpdater: NSViewRepresentable {
    @Environment(TabState.self) private var tab

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        tab.window = window
        if let client = tab.activeSession, client.isConnected, let selectedConnection = tab.selectedConnection {
            window.title = "\(selectedConnection.name) — \(selectedConnection.address)"
        } else {
            window.title = "Runlet"
        }
    }
}
