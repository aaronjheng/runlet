import Foundation
import Observation

// MARK: - Connection Store (Global singleton, shared across all tabs)

@MainActor
@Observable
class ConnectionStore {
    static let shared = ConnectionStore()

    var connections: [RedisConnectionConfig] = []
    private let database = AppDatabase.shared

    private init() {
        connections = database.loadConnections()
        if connections.isEmpty {
            connections = [.default]
        }
    }

    /// Adds a connection. Returns false (and leaves the in-memory list
    /// untouched) when the database write fails, so callers can surface the
    /// failure instead of showing a connection that will vanish on relaunch.
    @discardableResult
    func addConnection(_ config: RedisConnectionConfig) -> Bool {
        guard database.insertConnection(config) else { return false }
        connections.append(config)
        return true
    }

    /// Saves edits to a connection, inserting the row when it does not exist
    /// yet (matching the database upsert). Returns false when the write fails;
    /// the in-memory list is only mutated on success.
    @discardableResult
    func updateConnection(_ config: RedisConnectionConfig) -> Bool {
        guard database.updateConnection(config) else { return false }
        if let idx = connections.firstIndex(where: { $0.id == config.id }) {
            connections[idx] = config
        } else {
            connections.append(config)
        }
        return true
    }

    func deleteConnection(_ config: RedisConnectionConfig) {
        connections.removeAll { $0.id == config.id }
        database.deleteConnection(id: config.id)
    }

    func exportConnections(_ configs: [RedisConnectionConfig]) -> Data? {
        try? JSONEncoder().encode(configs)
    }

    func importConnections(from data: Data) -> [RedisConnectionConfig]? {
        try? JSONDecoder().decode([RedisConnectionConfig].self, from: data)
    }

    func addImportedConnections(_ configs: [RedisConnectionConfig]) {
        for config in configs {
            var newConfig = config
            newConfig.id = UUID()
            if database.insertConnection(newConfig) {
                connections.append(newConfig)
            }
        }
    }
}
