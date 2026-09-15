import Foundation

extension TabState {
    // MARK: - Server Info

    func loadServerInfo() async {
        guard let client = activeSession else { return }
        isLoadingServerInfo = true
        serverInfoError = nil
        defer { isLoadingServerInfo = false }
        do {
            let result: RESPValue
            var capabilityEndpoint: RedisEndpoint?

            if client.mode == .cluster {
                let nodes = try await client.clusterNodes()
                clusterNodes = nodes

                let selectedEndpoint =
                    selectedServerInfoNode.flatMap { endpoint in
                        nodes.contains { $0.endpoint == endpoint } ? endpoint : nil
                    }
                    ?? nodes.first(where: { $0.role == .primary })?.endpoint
                    ?? nodes.first?.endpoint
                selectedServerInfoNode = selectedEndpoint

                let clusterInfoResult = try await client.send(["CLUSTER", "INFO"])
                if case .error(let message) = clusterInfoResult {
                    throw RedisError.commandError(message)
                }
                if let clusterInfoString = clusterInfoResult.string {
                    clusterInfo = parseFlatInfo(clusterInfoString)
                }

                guard let selectedEndpoint else {
                    serverInfo = [:]
                    serverCapabilities = []
                    return
                }
                capabilityEndpoint = selectedEndpoint
                result = try await client.send(["INFO"], to: selectedEndpoint)
            } else {
                clusterInfo = [:]
                clusterNodes = []
                selectedServerInfoNode = nil
                result = try await client.send("INFO")
            }

            if case .error(let message) = result {
                throw RedisError.commandError(message)
            }
            guard let infoStr = result.string else { return }
            serverInfo = parseServerInfo(infoStr)
            let infoCapabilities = parseInfoModuleCapabilities(infoStr)
            serverCapabilities =
                await loadModuleCapabilities(using: client, endpoint: capabilityEndpoint)
                ?? infoCapabilities
        } catch {
            serverInfoError = error.localizedDescription
            AppLogger.error("Failed to load server info: \(error)", category: "ServerInfo")
        }
    }

    func selectServerInfoNode(_ endpoint: RedisEndpoint) async {
        selectedServerInfoNode = endpoint
        await loadServerInfoForSelectedNode()
    }

    /// Fetches only the per-node `INFO` for the currently selected node. The
    /// cluster topology (`CLUSTER NODES` / `CLUSTER INFO`) is global and is not
    /// re-fetched here, so switching nodes stays responsive.
    func loadServerInfoForSelectedNode() async {
        guard let client = activeSession else { return }
        guard client.mode == .cluster else { return }
        guard let endpoint = selectedServerInfoNode else { return }
        isLoadingServerInfo = true
        serverInfoError = nil
        defer { isLoadingServerInfo = false }
        do {
            let result = try await client.send(["INFO"], to: endpoint)
            if case .error(let message) = result {
                throw RedisError.commandError(message)
            }
            guard let infoStr = result.string else { return }
            serverInfo = parseServerInfo(infoStr)
            serverCapabilities = parseInfoModuleCapabilities(infoStr)
        } catch {
            serverInfoError = error.localizedDescription
            AppLogger.error("Failed to load server info for node: \(error)", category: "ServerInfo")
        }
    }

    private func parseServerInfo(_ infoStr: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var currentSection = ""
        for line in infoStr.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                currentSection = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                sections[currentSection] = [:]
            } else if let separatorIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<separatorIndex])
                let valueStart = trimmed.index(after: separatorIndex)
                sections[currentSection]?[key] = String(trimmed[valueStart...])
            }
        }
        return sections
    }

    private func parseFlatInfo(_ infoStr: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in infoStr.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separatorIndex = trimmed.firstIndex(of: ":") else {
                continue
            }
            let key = String(trimmed[..<separatorIndex])
            let valueStart = trimmed.index(after: separatorIndex)
            values[key] = String(trimmed[valueStart...])
        }
        return values
    }

    private func loadModuleCapabilities(
        using client: any RedisSession,
        endpoint: RedisEndpoint?
    ) async -> [RedisServerCapability]? {
        do {
            let result: RESPValue
            if client.mode == .cluster, let endpoint {
                result = try await client.send(["MODULE", "LIST"], to: endpoint)
            } else {
                result = try await client.send("MODULE", "LIST")
            }

            if case .error = result {
                return nil
            }
            return parseModuleListCapabilities(result)
        } catch {
            return nil
        }
    }

    private func parseModuleListCapabilities(_ value: RESPValue) -> [RedisServerCapability] {
        value.arrayValues.enumerated().compactMap { index, moduleValue in
            guard let moduleValue else { return nil }
            let fields = moduleValue.keyValuePairs.compactMap { pair -> (String, String)? in
                guard let key = pair.key.string?.lowercased() else { return nil }
                return (key, moduleValueDisplayString(pair.value))
            }
            guard !fields.isEmpty else { return nil }

            return moduleCapability(from: fields, fallbackName: "Module \(index + 1)")
        }
    }

    private func parseInfoModuleCapabilities(_ infoStr: String) -> [RedisServerCapability] {
        var capabilities: [RedisServerCapability] = []
        var isModulesSection = false

        for line in infoStr.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                isModulesSection = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) == "Modules"
                continue
            }

            guard isModulesSection, trimmed.hasPrefix("module:") else { continue }
            let payload = String(trimmed.dropFirst("module:".count))
            let fields = splitModuleInfoFields(payload).compactMap { field -> (String, String)? in
                guard let separatorIndex = field.firstIndex(of: "=") else { return nil }
                let key = String(field[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
                let valueStart = field.index(after: separatorIndex)
                let value = String(field[valueStart...]).trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key.lowercased(), value)
            }
            guard !fields.isEmpty else { continue }
            capabilities.append(moduleCapability(from: fields, fallbackName: "Module \(capabilities.count + 1)"))
        }

        return capabilities
    }

    private static let moduleFriendlyNames: [String: String] = [
        "bf": "Bloom Filter",
        "RedisBloom": "Bloom Filter",
        "ft": "RediSearch",
        "search": "RediSearch",
        "ts": "RedisTimeSeries",
        "timeseries": "RedisTimeSeries",
        "ReJSON": "RedisJSON",
        "json": "RedisJSON",
        "graph": "RedisGraph",
        "ai": "RedisAI",
        "rg": "RedisGears",
        "RedisGears": "RedisGears",
        "RedisGraph": "RedisGraph",
        "RedisAI": "RedisAI",
        "redis-cell": "RedisCell",
        "cell": "RedisCell",
        "bf-reserve": "Bloom Filter",
        "vectorset": "Vector Set",
    ]

    private func moduleCapability(
        from fields: [(String, String)],
        fallbackName: String
    ) -> RedisServerCapability {
        let rawName = fields.first { $0.0 == "name" }?.1 ?? fallbackName
        let name = Self.moduleFriendlyNames[rawName] ?? rawName
        let rawVersion = fields.first { $0.0 == "ver" }?.1
        let details = fields.compactMap { key, value -> RedisServerCapabilityDetail? in
            guard key != "name", key != "ver" else { return nil }
            return RedisServerCapabilityDetail(name: key, value: value)
        }

        return RedisServerCapability(
            name: name,
            version: rawVersion.map(moduleVersionDisplayString),
            details: details
        )
    }

    private func splitModuleInfoFields(_ payload: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var bracketDepth = 0

        for character in payload {
            switch character {
            case "[":
                bracketDepth += 1
                current.append(character)
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            case "," where bracketDepth == 0:
                fields.append(current)
                current = ""
            default:
                current.append(character)
            }
        }

        if !current.isEmpty {
            fields.append(current)
        }
        return fields
    }

    private func moduleValueDisplayString(_ value: RESPValue?) -> String {
        guard let value else { return "-" }
        switch value {
        case .array(let values):
            return "[" + values.map(moduleValueDisplayString).joined(separator: ", ") + "]"
        case .bulkString(let string):
            return string ?? "(nil)"
        case .simpleString(let string):
            return string
        case .integer(let integer):
            return "\(integer)"
        default:
            return value.displayString
        }
    }

    private func moduleVersionDisplayString(_ rawValue: String) -> String {
        guard let versionNumber = Int(rawValue), versionNumber >= 10_000 else {
            return rawValue
        }

        let major = versionNumber / 10_000
        let minor = (versionNumber / 100) % 100
        let patch = versionNumber % 100
        return "\(major).\(minor).\(patch) (\(rawValue))"
    }
}
