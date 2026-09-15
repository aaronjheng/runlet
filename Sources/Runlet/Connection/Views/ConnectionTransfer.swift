import SwiftUI
import UniformTypeIdentifiers

// MARK: - Connection Transfer

/// Import/export of connection configs through SwiftUI's file dialogs,
/// shared by the connection sidebar and the welcome screen.
@MainActor
enum ConnectionTransfer {
    /// Builds the JSON document to export, or nil when serialization fails.
    static func exportDocument(
        for configs: [RedisConnectionConfig],
        store: ConnectionStore
    ) -> ConnectionsDocument? {
        guard let data = store.exportConnections(configs) else { return nil }
        return ConnectionsDocument(
            json: data,
            defaultFilename: configs.count == 1
                ? "\(configs[0].name).json"
                : "redis-connections.json"
        )
    }

    /// Merges the configs from a completed fileImporter selection into the store.
    static func importConnections(from result: Result<[URL], Error>, store: ConnectionStore) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let data = try? Data(contentsOf: url),
            let configs = store.importConnections(from: data)
        else { return }
        store.addImportedConnections(configs)
    }
}

/// JSON wrapper for `fileExporter` of connection configs.
struct ConnectionsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json]

    let json: Data
    let defaultFilename: String

    init(json: Data, defaultFilename: String) {
        self.json = json
        self.defaultFilename = defaultFilename
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        json = data
        defaultFilename = "redis-connections.json"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: json)
    }
}
