import SwiftUI

// MARK: - Connection Hub View

struct ConnectionHubView: View {
    @Environment(TabState.self) private var tab
    @State private var cachedPanel: ConnectionPanel = .welcome

    var body: some View {
        Group {
            if tab.isConnecting || tab.activeSession?.isConnected == true {
                ConnectingView()
            } else {
                switch cachedPanel {
                case .editConnection, .newConnection:
                    ConnectionDetailView()
                        .frame(minWidth: 400)
                case .welcome:
                    WelcomeView()
                }
            }
        }
        .onChange(of: tab.connectionPanel) { _, newValue in
            cachedPanel = newValue
        }
        .onAppear {
            cachedPanel = tab.connectionPanel
        }
        .alert(
            "Connection Failed",
            isPresented: Binding(
                get: { tab.connectionError != nil },
                set: { if !$0 { tab.connectionError = nil } }
            ),
            presenting: tab.connectionError
        ) { _ in
            if tab.failedConnection != nil {
                Button("Retry") {
                    if let config = tab.failedConnection {
                        Task { await tab.connect(to: config) }
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }
}
