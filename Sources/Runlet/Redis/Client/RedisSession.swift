import Foundation

struct RedisEndpoint: Codable, Hashable, Sendable {
    var host: String
    var port: UInt16

    var address: String {
        "\(host):\(port)"
    }

    static func parse(_ value: String, defaultPort: UInt16 = 6379) -> RedisEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://"), let components = URLComponents(string: trimmed), let host = components.host {
            return RedisEndpoint(host: host, port: UInt16(components.port ?? Int(defaultPort)))
        }

        if trimmed.hasPrefix("["), let closeIndex = trimmed.firstIndex(of: "]") {
            let hostStart = trimmed.index(after: trimmed.startIndex)
            let host = String(trimmed[hostStart..<closeIndex])
            let afterClose = trimmed.index(after: closeIndex)
            if afterClose < trimmed.endIndex, trimmed[afterClose] == ":" {
                let portStart = trimmed.index(after: afterClose)
                if let port = UInt16(trimmed[portStart...]) {
                    return RedisEndpoint(host: host, port: port)
                }
            }
            return RedisEndpoint(host: host, port: defaultPort)
        }

        if let colonIndex = trimmed.lastIndex(of: ":"), colonIndex > trimmed.startIndex {
            // Bare IPv6 (e.g. "::1") must not be split at the last colon — only
            // treat the suffix as a port when it parses AND the remainder looks
            // like a hostname/IPv4 (bracketed IPv6 is handled above).
            let portStart = trimmed.index(after: colonIndex)
            if let port = UInt16(trimmed[portStart...]), !trimmed.contains("::") {
                let host = String(trimmed[..<colonIndex])
                return RedisEndpoint(host: host, port: port)
            }
        }

        return RedisEndpoint(host: trimmed, port: defaultPort)
    }

    static func parseList(_ value: String, defaultPort: UInt16 = 6379) -> [RedisEndpoint] {
        let separators = CharacterSet(charactersIn: ",;\n\t ")
        let parts = value.components(separatedBy: separators)
        return unique(parts.compactMap { RedisEndpoint.parse($0, defaultPort: defaultPort) })
    }

    static func unique(_ endpoints: [RedisEndpoint]) -> [RedisEndpoint] {
        var seen: Set<RedisEndpoint> = []
        var result: [RedisEndpoint] = []
        for endpoint in endpoints where !endpoint.host.isEmpty {
            if seen.insert(endpoint).inserted {
                result.append(endpoint)
            }
        }
        return result
    }
}

enum RedisConnectionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case standalone
    case cluster

    var title: String {
        switch self {
        case .standalone: return "Standalone"
        case .cluster: return "Cluster"
        }
    }
}

struct RedisScanResult: Sendable {
    let nextCursor: String
    let keys: [String]
    let scannedCount: Int

    init(nextCursor: String, keys: [String], scannedCount: Int = 0) {
        self.nextCursor = nextCursor
        self.keys = keys
        self.scannedCount = scannedCount
    }

    init(response: RESPValue, scannedCount: Int = 0) throws {
        if case .error(let message) = response {
            throw RedisError.commandError(message)
        }
        let values = response.arrayValues
        // Some servers reply with an integer cursor ("0"); accept both shapes.
        guard values.count >= 2 else {
            throw RedisError.parseError("Unexpected SCAN response: \(response.description)")
        }
        let cursor: String
        if let stringCursor = values[0]?.string {
            cursor = stringCursor
        } else if let integerCursor = values[0]?.intValue {
            cursor = "\(integerCursor)"
        } else {
            throw RedisError.parseError("Unexpected SCAN response: \(response.description)")
        }
        nextCursor = cursor
        keys = values[1]?.arrayValues.compactMap { $0?.string } ?? []
        self.scannedCount = scannedCount
    }
}

enum RedisClusterNodeRole: String, Hashable, Sendable {
    case primary
    case replica

    var title: String {
        switch self {
        case .primary: return "Primary"
        case .replica: return "Replica"
        }
    }
}

struct RedisClusterSlotRangeSummary: Hashable, Sendable {
    let start: Int
    let end: Int

    var label: String {
        start == end ? "\(start)" : "\(start)-\(end)"
    }

    var count: Int {
        max(0, end - start + 1)
    }
}

struct RedisClusterNodeSummary: Identifiable, Hashable, Sendable {
    let endpoint: RedisEndpoint
    let role: RedisClusterNodeRole
    let slotRanges: [RedisClusterSlotRangeSummary]
    let replicaOf: RedisEndpoint?

    var id: String {
        endpoint.address
    }

    var slotSummary: String {
        guard !slotRanges.isEmpty else { return "-" }
        return slotRanges.map(\.label).joined(separator: ", ")
    }

    var coveredSlotCount: Int {
        slotRanges.reduce(0) { $0 + $1.count }
    }
}

protocol RedisSession: AnyObject, Sendable {
    var mode: RedisConnectionMode { get }
    var isConnected: Bool { get }
    var lastError: String? { get }

    func connect() async throws
    func disconnect()
    func send(_ args: String...) async throws -> RESPValue
    func send(_ args: [String]) async throws -> RESPValue
    func sendPipeline(_ commands: [[String]]) async throws -> [RESPValue]
    func scan(cursor: String, match: String, count: Int) async throws -> RedisScanResult
    func totalKeyCount() async throws -> Int?

    /// Known node topology. Standalone sessions report the single node they
    /// serve; cluster sessions report every known node. Lets callers stay on
    /// the protocol instead of downcasting to the cluster client.
    func clusterNodes() async throws -> [RedisClusterNodeSummary]
    /// Sends a command to a specific node. Standalone sessions serve their
    /// single node and reject any other endpoint.
    func send(_ args: [String], to endpoint: RedisEndpoint) async throws -> RESPValue
}

protocol RedisClusterEndpointResolver: Sendable {
    func clientEndpoint(for endpoint: RedisEndpoint) async throws -> RedisEndpoint
    func disconnect() async
}

extension RedisClient: RedisSession {
    var mode: RedisConnectionMode { .standalone }

    func scan(cursor: String, match: String, count: Int) async throws -> RedisScanResult {
        let count = min(max(count, 1), 10_000)
        let response = try await send("SCAN", cursor, "MATCH", match, "COUNT", "\(count)")
        return try RedisScanResult(response: response, scannedCount: count)
    }

    func totalKeyCount() async throws -> Int? {
        try await fetchRedisTotalKeyCount { command in
            try await self.send(command)
        }
    }

    func clusterNodes() async throws -> [RedisClusterNodeSummary] {
        [
            RedisClusterNodeSummary(
                endpoint: RedisEndpoint(host: host, port: port),
                role: .primary,
                slotRanges: [],
                replicaOf: nil
            )
        ]
    }

    func send(_ args: [String], to endpoint: RedisEndpoint) async throws -> RESPValue {
        guard endpoint.host == host, endpoint.port == port else {
            throw RedisError.commandError(
                "Standalone session serves \(host):\(port); cannot target \(endpoint.address)"
            )
        }
        return try await send(args)
    }
}

func fetchRedisTotalKeyCount(
    _ sendCommand: ([String]) async throws -> RESPValue
) async throws -> Int? {
    do {
        let dbSizeResponse = try await sendCommand(["DBSIZE"])
        try throwIfRedisError(dbSizeResponse)
        if let count = dbSizeResponse.intValue {
            return count
        }
    } catch {
        AppLogger.debug("DBSIZE failed while counting keys: \(error)", category: "Redis")
    }

    let infoResponse = try await sendCommand(["INFO", "keyspace"])
    try throwIfRedisError(infoResponse)
    guard let info = infoResponse.string else { return nil }
    return keyCountFromKeyspaceInfo(info, database: 0)
}

func keyCountFromKeyspaceInfo(_ info: String, database: Int) -> Int? {
    let databasePrefix = "db\(database):"

    for rawLine in info.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(databasePrefix) else { continue }

        let fields = line.dropFirst(databasePrefix.count).split(separator: ",")
        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "keys" else { continue }
            return Int(parts[1])
        }
        return nil
    }

    return nil
}

func throwIfRedisError(_ value: RESPValue) throws {
    if case .error(let message) = value {
        throw RedisError.commandError(message)
    }
}

/// Builds the session for a connection, standalone or cluster, from one
/// place: the credential/TLS mapping and the mode switch shared by the main
/// connection, the shell session, and the connection probe.
///
/// `seedNodes` is taken as given (callers pass the resolved seeds) so this
/// helper changes no routing behavior.
func makeRedisSession(
    config: RedisConnectionConfig,
    host: String,
    port: UInt16,
    seedNodes: [RedisEndpoint],
    endpointResolver: (any RedisClusterEndpointResolver)?
) -> any RedisSession {
    switch config.mode {
    case .standalone:
        RedisClient(
            host: host,
            port: port,
            username: config.username.isEmpty ? nil : config.username,
            password: config.password.isEmpty ? nil : config.password,
            tlsEnabled: config.tls.enabled,
            verifyServerCertificate: config.tls.verifyServerCertificate,
            caCertificatePath: config.tls.caCertificatePath,
            clientCertificatePath: config.tls.clientCertificatePath,
            clientKeyPath: config.tls.clientKeyPath,
            connectionTimeout: config.connectionTimeout
        )
    case .cluster:
        RedisClusterClient(
            seedNodes: seedNodes,
            username: config.username.isEmpty ? nil : config.username,
            password: config.password.isEmpty ? nil : config.password,
            tlsEnabled: config.tls.enabled,
            verifyServerCertificate: config.tls.verifyServerCertificate,
            caCertificatePath: config.tls.caCertificatePath,
            clientCertificatePath: config.tls.clientCertificatePath,
            clientKeyPath: config.tls.clientKeyPath,
            connectionTimeout: config.connectionTimeout,
            endpointResolver: endpointResolver
        )
    }
}

enum RedisError: LocalizedError {
    case notConnected
    case parseError(String)
    case commandError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Redis server"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .commandError(let msg): return "Command error: \(msg)"
        }
    }

    var isUnknownCommand: Bool {
        guard case .commandError(let message) = self else { return false }
        return message.localizedCaseInsensitiveContains("unknown command")
    }
}
