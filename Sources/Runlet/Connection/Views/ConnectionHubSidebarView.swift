import SwiftUI

// MARK: - Connection Hub Sidebar

struct ConnectionHubSidebarView: View {
    @Environment(TabState.self) private var tab
    @Environment(ConnectionStore.self) private var store
    @State private var connectionPendingDeletion: RedisConnectionConfig?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: ConnectionsDocument?
    @State private var hoveredConnectionID: RedisConnectionConfig.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connections")
                    .font(.headline)
                Spacer()
                Button("Export All Connections", systemImage: "square.and.arrow.up") {
                    beginExport(store.connections)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Export All Connections")
                Button("Import Connections", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Import Connections")
                Button("New Connection", systemImage: "plus") {
                    tab.selectedConnection = nil
                    tab.connectionPanel = .newConnection
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("New Connection")
            }
            .panelToolbar(horizontalPadding: AppSpacing.small)

            Divider()

            List(
                selection: Binding(
                    get: { tab.selectedConnection },
                    set: {
                        tab.selectedConnection = $0
                        if let selectedConnection = $0 {
                            tab.connectionPanel = .editConnection(selectedConnection)
                        }
                    }
                )
            ) {
                ForEach(store.connections) { config in
                    ConnectionRow(
                        config: config,
                        isConnected: false,
                        isSelected: tab.selectedConnection?.id == config.id,
                        isHovering: hoveredConnectionID == config.id
                    )
                    .tag(config)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .overlay(
                        DoubleClickHandler(
                            onDoubleClick: {
                                Task { await tab.connect(to: config) }
                            },
                            onHover: { hovering in
                                if hovering {
                                    hoveredConnectionID = config.id
                                } else if hoveredConnectionID == config.id {
                                    hoveredConnectionID = nil
                                }
                            }
                        )
                    )
                    .contextMenu {
                        Button("Duplicate") {
                            var copy = config
                            copy.id = UUID()
                            copy.name = "\(config.name) Copy"
                            store.addConnection(copy)
                            tab.selectedConnection = copy
                            tab.connectionPanel = .editConnection(copy)
                        }
                        Button("Delete", role: .destructive) {
                            connectionPendingDeletion = config
                        }
                        Divider()
                        Button("Copy Address") {
                            copyToPasteboard(config.address)
                        }
                        Button("Copy URI") {
                            var uri = "redis://"
                            if !config.username.isEmpty || !config.password.isEmpty {
                                if !config.username.isEmpty {
                                    uri += config.username
                                }
                                if !config.password.isEmpty {
                                    uri += ":\(config.password)"
                                }
                                uri += "@"
                            }
                            uri += "\(config.host):\(config.port)"
                            copyToPasteboard(uri)
                        }
                        Divider()
                        Button("Export...") {
                            beginExport([config])
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .flatSidebarBackground()
        }
        .confirmationDialog(
            "Delete Connection",
            isPresented: Binding(
                get: { connectionPendingDeletion != nil },
                set: { if !$0 { connectionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let config = connectionPendingDeletion {
                Button("Delete", role: .destructive) {
                    store.deleteConnection(config)
                    if tab.selectedConnection?.id == config.id {
                        tab.selectedConnection = nil
                        tab.connectionPanel = .welcome
                    }
                    connectionPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                connectionPendingDeletion = nil
            }
        } message: {
            if let config = connectionPendingDeletion {
                Text("This permanently deletes \"\(config.name)\" (\(config.address)).")
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportDocument?.defaultFilename
        ) { _ in }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            ConnectionTransfer.importConnections(from: result, store: store)
        }
    }

    private func beginExport(_ configs: [RedisConnectionConfig]) {
        guard let document = ConnectionTransfer.exportDocument(for: configs, store: store) else { return }
        exportDocument = document
        isExporting = true
    }
}
