import Foundation
import SQLite3
import Synchronization

// MARK: - App Database

/// SQLite-backed persistence shared across feature areas: connection configs
/// and shell command history live in one database file (`runlet.sqlite`)
/// in Application Support. `libsqlite3` is a system framework, so no
/// third-party dependency is added. All access is serialized through a mutex;
/// the connection is additionally opened with `SQLITE_OPEN_FULLMUTEX`.
final class AppDatabase: Sendable {
    static let shared = AppDatabase()

    /// Guard held for the duration of every SQLite call below.
    private let db: Mutex<OpaquePointer?>

    /// SQLite's `SQLITE_TRANSIENT` destructor, not exported to Swift as a
    /// constant (it is a C macro). Signals SQLite to copy the bound text.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        var handle: OpaquePointer?
        if let directory = Self.directoryURL {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent(AppSupportDirectory.databaseFileName).path
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            var opened: OpaquePointer?
            if sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK, let db = opened {
                Self.createSchema(in: db)
                handle = db
            }
        }
        db = Mutex(handle)
    }

    deinit {
        db.withLock { handle in
            if let handle {
                sqlite3_close(handle)
            }
        }
    }

    private static let directoryURL = AppSupportDirectory.current

    private static func createSchema(in db: OpaquePointer) {
        let schema = """
            CREATE TABLE IF NOT EXISTS connections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                environment TEXT NOT NULL,
                payload TEXT NOT NULL,
                sort_order INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_connections_sort ON connections (sort_order);
            CREATE TABLE IF NOT EXISTS shell_history (
                id TEXT PRIMARY KEY,
                connection_id TEXT NOT NULL,
                command TEXT NOT NULL,
                result TEXT NOT NULL,
                timestamp REAL NOT NULL,
                is_error INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_shell_history_connection
                ON shell_history (connection_id, timestamp);
            """
        _ = sqlite3_exec(db, schema, nil, nil, nil)
    }

    // MARK: - Connections

    /// Loads all connection configs in saved order.
    func loadConnections() -> [RedisConnectionConfig] {
        db.withLock { handle in
            guard let handle else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT payload FROM connections ORDER BY sort_order"
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var configs: [RedisConnectionConfig] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let json = Self.text(stmt, 0),
                    let payload = json.data(using: .utf8),
                    let config = try? JSONDecoder().decode(RedisConnectionConfig.self, from: payload)
                else { continue }
                configs.append(config)
            }
            return configs
        }
    }

    /// Inserts a connection config at the end of the saved order. Returns
    /// false when the row was not written.
    @discardableResult
    func insertConnection(_ config: RedisConnectionConfig) -> Bool {
        write(
            config,
            sql: """
                INSERT INTO connections (name, environment, payload, id, sort_order)
                VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM connections))
                """
        )
    }

    /// Saves a connection config in place, inserting the row when it does not
    /// exist yet. The insert case matters for configs that live only in memory
    /// (e.g. the seeded default connection on a fresh database): a bare UPDATE
    /// would match zero rows and silently drop the edit. Returns false when
    /// the row was not written.
    @discardableResult
    func updateConnection(_ config: RedisConnectionConfig) -> Bool {
        write(
            config,
            sql: """
                INSERT INTO connections (name, environment, payload, id, sort_order)
                VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM connections))
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    environment = excluded.environment,
                    payload = excluded.payload
                """
        )
    }

    /// Deletes a connection config.
    func deleteConnection(id: UUID) {
        execute("DELETE FROM connections WHERE id = ?", [id.uuidString])
    }

    @discardableResult
    private func write(_ config: RedisConnectionConfig, sql: String) -> Bool {
        guard let payload = try? JSONEncoder().encode(config),
            let json = String(data: payload, encoding: .utf8)
        else {
            AppLogger.error("connection write failed: encoding error name=\(config.name)", category: "Database")
            return false
        }
        return db.withLock { handle in
            guard let handle else {
                AppLogger.error(
                    "connection write failed: database unavailable name=\(config.name)", category: "Database"
                )
                return false
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                AppLogger.error(
                    "connection write failed: prepare name=\(config.name) error=\(String(cString: sqlite3_errmsg(handle)))",
                    category: "Database"
                )
                return false
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, config.name, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 2, config.environment.rawValue, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 3, json, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 4, config.id.uuidString, -1, Self.sqliteTransient)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                AppLogger.error(
                    "connection write failed: step rc=\(rc) name=\(config.name) "
                        + "error=\(String(cString: sqlite3_errmsg(handle)))",
                    category: "Database"
                )
                return false
            }
            return true
        }
    }

    // MARK: - Shell History

    /// Loads the history for a connection, ordered oldest-first (matching the
    /// in-memory array order), capped at `limit`.
    func loadHistory(connectionID: UUID, limit: Int) -> [ShellHistoryEntry] {
        db.withLock { handle in
            guard let handle else { return [] }
            let sql = """
                SELECT id, command, result, timestamp, is_error
                FROM shell_history
                WHERE connection_id = ?
                ORDER BY timestamp DESC, rowid DESC
                LIMIT ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, connectionID.uuidString, -1, Self.sqliteTransient)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var entries: [ShellHistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let id = Self.text(stmt, 0).flatMap(UUID.init(uuidString:)),
                    let command = Self.text(stmt, 1),
                    let result = Self.text(stmt, 2)
                else { continue }
                entries.append(
                    ShellHistoryEntry(
                        id: id,
                        command: command,
                        result: result,
                        timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                        isError: sqlite3_column_int(stmt, 4) != 0
                    ))
            }
            return entries.reversed()
        }
    }

    /// Appends an entry and prunes the connection's history to `limit` rows.
    func appendHistory(_ entry: ShellHistoryEntry, connectionID: UUID, limit: Int) {
        db.withLock { handle in
            guard let handle else { return }
            var stmt: OpaquePointer?
            let sql = """
                INSERT OR REPLACE INTO shell_history (id, connection_id, command, result, timestamp, is_error)
                VALUES (?, ?, ?, ?, ?, ?)
                """
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, entry.id.uuidString, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 2, connectionID.uuidString, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 3, entry.command, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 4, entry.result, -1, Self.sqliteTransient)
            sqlite3_bind_double(stmt, 5, entry.timestamp.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 6, entry.isError ? 1 : 0)
            sqlite3_step(stmt)

            Self.pruneHistory(connectionID: connectionID, limit: limit, in: handle)
        }
    }

    /// Deletes a single history entry.
    func deleteHistory(id: UUID, connectionID: UUID) {
        execute(
            "DELETE FROM shell_history WHERE id = ? AND connection_id = ?",
            [id.uuidString, connectionID.uuidString]
        )
    }

    /// Removes all history for a connection.
    func clearHistory(connectionID: UUID) {
        execute("DELETE FROM shell_history WHERE connection_id = ?", [connectionID.uuidString])
    }

    // MARK: - Private

    /// Drops rows beyond the newest `limit` for a connection.
    private static func pruneHistory(connectionID: UUID, limit: Int, in db: OpaquePointer) {
        let sql = """
            DELETE FROM shell_history
            WHERE connection_id = ?1 AND id NOT IN (
                SELECT id FROM shell_history
                WHERE connection_id = ?1
                ORDER BY timestamp DESC, rowid DESC
                LIMIT ?2
            )
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, connectionID.uuidString, -1, sqliteTransient)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        sqlite3_step(stmt)
    }

    /// Runs a statement with text-bound arguments, ignoring failures the way
    /// the rest of the persistence layer does (data loss on a failed write is
    /// acceptable for these caches).
    private func execute(_ sql: String, _ arguments: [String]) {
        db.withLock { handle in
            guard let handle else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            for (index, argument) in arguments.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), argument, -1, Self.sqliteTransient)
            }
            sqlite3_step(stmt)
        }
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
}
