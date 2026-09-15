import Foundation

// MARK: - Routing / Topology

/// Slot routing and topology refresh for `RedisClusterClient`: key hashing to
/// slot, CLUSTER SLOTS parsing, and direct per-node sends.
extension RedisClusterClient {
    func routeEndpoint(for args: [String]) async throws -> RedisEndpoint {
        let keys = try RedisClusterCommandKeys.keys(in: args)
        guard !keys.isEmpty else {
            if let endpoint = await state.defaultEndpoint() {
                return endpoint
            }
            return seedNodes[0]
        }

        let slots = Set(keys.map { RedisClusterHash.slot(for: $0) })
        guard slots.count == 1, let slot = slots.first else {
            throw RedisError.commandError("Command keys do not hash to the same Redis Cluster slot")
        }

        if let endpoint = await state.owner(for: slot) {
            return endpoint
        }

        try await refreshTopology(preferredEndpoint: nil)
        if let endpoint = await state.owner(for: slot) {
            return endpoint
        }

        throw RedisError.commandError("Redis Cluster topology does not cover slot \(slot)")
    }

    func primaryEndpointsForCommand() async throws -> [RedisEndpoint] {
        guard isConnected else {
            throw RedisError.notConnected
        }

        var primaries = await state.primaryEndpoints()
        if primaries.isEmpty {
            try await refreshTopology(preferredEndpoint: nil)
            primaries = await state.primaryEndpoints()
        }
        guard !primaries.isEmpty else {
            throw RedisError.commandError("Redis Cluster topology has no primary nodes")
        }
        return primaries
    }

    func sendDirect(_ args: [String], to endpoint: RedisEndpoint, asking: Bool) async throws -> RESPValue {
        let client = try await state.client(
            for: endpoint,
            endpointResolver: endpointResolver,
            makeClient: makeClient
        )
        if asking {
            let response = try await client.send("ASKING")
            if case .error = response {
                return response
            }
        }
        return try await client.send(args)
    }

    func sendDirectPipeline(_ commands: [[String]], to endpoint: RedisEndpoint) async throws -> [RESPValue] {
        let client = try await state.client(
            for: endpoint,
            endpointResolver: endpointResolver,
            makeClient: makeClient
        )
        return try await client.sendPipeline(commands)
    }

    func refreshTopology(preferredEndpoint: RedisEndpoint?) async throws {
        var candidates: [RedisEndpoint] = []
        if let preferredEndpoint {
            candidates.append(preferredEndpoint)
        }
        candidates.append(contentsOf: await state.primaryEndpoints())
        candidates.append(contentsOf: seedNodes)
        candidates = RedisEndpoint.unique(candidates)

        var lastError: Error?
        for endpoint in candidates {
            do {
                let client = try await state.client(
                    for: endpoint,
                    endpointResolver: endpointResolver,
                    makeClient: makeClient
                )
                let response = try await client.send("CLUSTER", "SLOTS")
                if case .error(let message) = response {
                    throw RedisError.commandError(
                        "Selected mode is Cluster, but \(endpoint.address) did not return cluster slots: \(message)"
                    )
                }

                let ranges = try Self.parseClusterSlots(response, fallbackHost: endpoint.host)
                await state.updateTopology(ranges, defaultEndpoint: endpoint)
                try await validateClusterState(using: client, endpoint: endpoint)
                return
            } catch {
                lastError = error
                AppLogger.debug("cluster topology refresh failed endpoint=\(endpoint.address) error=\(error)")
            }
        }

        throw lastError ?? RedisError.commandError("Unable to load Redis Cluster topology")
    }

    private func validateClusterState(using client: RedisClient, endpoint: RedisEndpoint) async throws {
        let response = try await client.send("CLUSTER", "INFO")
        if case .error(let message) = response {
            throw RedisError.commandError("Unable to read Redis Cluster state from \(endpoint.address): \(message)")
        }
        guard let info = response.string else { return }
        guard
            info.components(separatedBy: "\n").contains(where: { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines) == "cluster_state:ok"
            })
        else {
            throw RedisError.commandError("Redis Cluster state is not ok on \(endpoint.address)")
        }
    }

    private static func parseClusterSlots(_ value: RESPValue, fallbackHost: String) throws -> [RedisClusterSlotRange] {
        let items = value.arrayValues
        var ranges: [RedisClusterSlotRange] = []

        for item in items {
            guard let entry = item?.arrayValues, entry.count >= 3,
                let start = entry[0]?.intValue,
                let end = entry[1]?.intValue,
                let primaryNode = entry[2]?.arrayValues
            else {
                AppLogger.error("Skipping malformed CLUSTER SLOTS entry", category: "Cluster")
                continue
            }

            let primary = try parseNodeEndpoint(primaryNode, fallbackHost: fallbackHost)
            var replicas: [RedisEndpoint] = []
            for node in entry.dropFirst(3) {
                guard let values = node?.arrayValues else {
                    AppLogger.error("Skipping malformed replica entry in CLUSTER SLOTS", category: "Cluster")
                    continue
                }
                if let replica = try? parseNodeEndpoint(values, fallbackHost: fallbackHost) {
                    replicas.append(replica)
                } else {
                    AppLogger.error("Skipping unparseable replica endpoint in CLUSTER SLOTS", category: "Cluster")
                }
            }
            ranges.append(RedisClusterSlotRange(start: start, end: end, primary: primary, replicas: replicas))
        }

        guard !ranges.isEmpty else {
            throw RedisError.parseError("Unexpected CLUSTER SLOTS response")
        }
        return ranges
    }

    private static func parseNodeEndpoint(_ values: [RESPValue?], fallbackHost: String) throws -> RedisEndpoint {
        guard values.count >= 2,
            let portValue = values[1]?.intValue,
            let port = UInt16(exactly: portValue)
        else {
            throw RedisError.parseError("Unexpected CLUSTER SLOTS node endpoint")
        }

        let rawHost = values[0]?.string ?? ""
        let host = rawHost.isEmpty || rawHost == "?" ? fallbackHost : rawHost
        return RedisEndpoint(host: host, port: port)
    }
}
