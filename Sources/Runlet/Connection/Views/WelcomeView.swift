import AppKit
import SwiftUI

// MARK: - Welcome View

struct WelcomeView: View {
    @Environment(TabState.self) private var tab
    @Environment(ConnectionStore.self) private var store
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: AppSpacing.xLarge) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

            VStack(spacing: AppSpacing.small) {
                Text("Runlet")
                    .font(.largeTitle.weight(.semibold))
                Text("Connect to a Redis database to browse keys, run commands, and monitor performance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack(spacing: AppSpacing.medium) {
                Button {
                    tab.selectedConnection = nil
                    tab.connectionPanel = .newConnection
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    isImporting = true
                } label: {
                    Label("Import Connections", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Text("Tip: Double-click a connection in the sidebar to connect.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            ConnectionTransfer.importConnections(from: result, store: store)
        }
    }
}
