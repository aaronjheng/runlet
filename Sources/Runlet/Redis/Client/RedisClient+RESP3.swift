import Foundation

// MARK: - RESP3 Handshake

/// RESP3 negotiation for `RedisClient`: HELLO, capability capture, and the
/// fallback path to RESP2 for pre-7.0 servers.
extension RedisClient {
    // MARK: - RESP3 Handshake

    @discardableResult
    func performResp3Handshake() async throws -> Bool {
        let result = try await sendHelloCommand(protocolVersion: .resp3, includeAuthentication: helloCommandIncludesAuthentication)
        let helloIncludesAuthentication = helloCommandIncludesAuthentication

        switch result {
        case .map(let entries):
            // RESP3 HELLO response is a map with server info
            serverCapabilities = normalizedHelloCapabilities(from: entries)
            negotiatedProtocolVersion = .resp3
            if let fallbackReason = resp3FallbackReason(serverVersion: serverVersion) {
                try await downgradeToResp2(serverVersion: serverVersion, fallbackReason: fallbackReason)
            }
            return helloIncludesAuthentication

        case .error(let message):
            // HELLO command failed, fall back to RESP2
            AppLogger.debug("RESP3 handshake failed: \(message), falling back to RESP2")
            negotiatedProtocolVersion = .resp2
            protocolFallbackReason = "resp3_handshake_failed"
            return false

        default:
            // Unexpected response, fall back to RESP2
            AppLogger.debug("Unexpected HELLO response, falling back to RESP2")
            negotiatedProtocolVersion = .resp2
            protocolFallbackReason = "unexpected_hello_response"
            return false
        }
    }

    private func sendHelloCommand(
        protocolVersion: RESPProtocolVersion,
        includeAuthentication: Bool
    ) async throws -> RESPValue {
        let data = RESPEncoder.encode(
            helloCommandArguments(protocolVersion: protocolVersion, includeAuthentication: includeAuthentication),
            version: .resp2
        )

        return try await sendEncodedCommand(data, isBlocking: false)
    }

    private var helloCommandIncludesAuthentication: Bool {
        let user = username ?? ""
        let pw = password ?? ""
        return !user.isEmpty || !pw.isEmpty
    }

    private func helloCommandArguments(
        protocolVersion: RESPProtocolVersion,
        includeAuthentication: Bool
    ) -> [String] {
        var args = ["HELLO", protocolVersion.helloArgument]
        guard includeAuthentication else { return args }

        let user = username ?? ""
        let pw = password ?? ""
        args.append(contentsOf: ["AUTH", user.isEmpty ? "default" : user, pw])
        return args
    }

    private var serverVersion: String? {
        serverCapabilities["version"]?.string ?? serverCapabilities["redis_version"]?.string
    }

    private func normalizedHelloCapabilities(from entries: [RESPMapEntry]) -> [String: RESPValue] {
        normalizedHelloCapabilities(from: entries.map { (key: $0.key, value: $0.value) })
    }

    private func normalizedHelloCapabilities(from pairs: [(key: RESPValue, value: RESPValue)]) -> [String: RESPValue] {
        pairs.reduce(into: [:]) { dict, pair in
            guard let keyString = pair.key.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                !keyString.isEmpty
            else {
                return
            }
            dict[keyString] = pair.value
        }
    }

    private func resp3FallbackReason(serverVersion: String?) -> String? {
        guard let serverVersion else {
            return "missing_server_version_after_hello3"
        }

        guard let majorVersion = serverMajorVersion(from: serverVersion) else {
            return "unparseable_server_version_after_hello3"
        }

        guard majorVersion >= 7 else {
            return "redis_resp3_experimental_before_7"
        }

        return nil
    }

    private func serverMajorVersion(from serverVersion: String) -> Int? {
        let majorComponent = serverVersion.split(separator: ".", maxSplits: 1).first ?? Substring(serverVersion)
        let majorDigits = majorComponent.prefix { $0.isNumber }
        return Int(majorDigits)
    }

    private func downgradeToResp2(serverVersion: String?, fallbackReason: String) async throws {
        let result = try await sendHelloCommand(protocolVersion: .resp2, includeAuthentication: false)
        if case .error(let message) = result {
            let serverDescription = serverVersion.map { "Redis \($0)" } ?? "Redis server"
            throw RedisError.commandError("Unable to use RESP2 for \(serverDescription): \(message)")
        }

        state.withLock {
            $0.serverCapabilities.merge(normalizedHelloCapabilities(from: result.keyValuePairs)) { _, new in new }
            $0.negotiatedProtocolVersion = .resp2
            $0.serverCapabilities["proto"] = .integer(2)
            $0.protocolFallbackReason = fallbackReason
        }
    }

    func logNegotiatedProtocol(authenticatedByHello: Bool) {
        var fields = [
            "auth_via_hello": "\(authenticatedByHello)",
            "host": host,
            "negotiated_protocol": negotiatedProtocolVersion.logName,
            "port": "\(port)",
            "preferred_protocol": preferredProtocolVersion.logName,
            "tls_enabled": "\(tlsEnabled)",
        ]
        if let serverVersion {
            fields["server_version"] = serverVersion
        }
        if serverVersion == nil, !serverCapabilities.isEmpty {
            fields["hello_keys"] = serverCapabilities.keys.sorted().joined(separator: ",")
        }
        if let serverProtocol = serverCapabilities["proto"]?.intValue {
            fields["server_protocol"] = "\(serverProtocol)"
        }
        if let protocolFallbackReason {
            fields["fallback_reason"] = protocolFallbackReason
        }

        AppLogger.info(
            "redis protocol negotiated",
            category: "Connection",
            fields: fields
        )
    }

}
