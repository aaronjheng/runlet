import Foundation

// MARK: - Command Dispatch

/// Cluster command dispatch for `RedisClusterClient`: the MOVED/ASK redirect
/// loop, fan-out pipelines, node-round-robin SCAN, and per-node sends.
extension RedisClusterClient {
    func send(_ args: String...) async throws -> RESPValue {
        try await send(args)
    }

    func send(_ args: [String]) async throws -> RESPValue {
        guard isConnected else {
            throw RedisError.notConnected
        }
        guard !args.isEmpty else {
            throw RedisError.commandError("Redis command is empty")
        }

        var forcedEndpoint: RedisEndpoint?
        var shouldSendAsking = false
        var attempt = 0
        let maxAttempts = 5

        while attempt < maxAttempts {
            let endpoint: RedisEndpoint
            if let forcedEndpoint {
                endpoint = forcedEndpoint
            } else {
                endpoint = try await routeEndpoint(for: args)
            }
            let response = try await sendDirect(args, to: endpoint, asking: shouldSendAsking)

            if case .error(let message) = response {
                // Transient cluster states: retry with backoff instead of
                // failing the caller's command.
                if RedisClusterRetryableError.isRetryable(message) {
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(50 * attempt))
                    continue
                }
                if let redirect = RedisClusterRedirect(message: message, fallbackHost: endpoint.host) {
                    attempt += 1
                    switch redirect.kind {
                    case .moved:
                        await state.replaceOwner(slot: redirect.slot, with: redirect.endpoint)
                        try? await refreshTopology(preferredEndpoint: redirect.endpoint)
                        forcedEndpoint = redirect.endpoint
                        shouldSendAsking = false
                    case .ask:
                        forcedEndpoint = redirect.endpoint
                        shouldSendAsking = true
                    }
                    continue
                }
            }

            return response
        }

        throw RedisError.commandError("Too many Redis Cluster redirects")
    }

    func sendPipeline(_ commands: [[String]]) async throws -> [RESPValue] {
        guard isConnected else {
            throw RedisError.notConnected
        }
        guard !commands.isEmpty else { return [] }
        guard commands.allSatisfy({ !$0.isEmpty }) else {
            throw RedisError.commandError("Redis command is empty")
        }

        var groupedCommands: [RedisEndpoint: [(index: Int, command: [String])]] = [:]
        for (index, command) in commands.enumerated() {
            let endpoint = try await routeEndpoint(for: command)
            groupedCommands[endpoint, default: []].append((index, command))
        }

        let groupedBatches = groupedCommands.map { endpoint, commands in
            (endpoint: endpoint, commands: commands)
        }
        var orderedResponses = [RESPValue?](repeating: nil, count: commands.count)

        try await withThrowingTaskGroup(
            of: [(index: Int, command: [String], endpoint: RedisEndpoint, response: RESPValue)].self
        ) { group in
            for batch in groupedBatches {
                group.addTask { [self] in
                    let batchCommands = batch.commands.map(\.command)
                    let responses = try await sendDirectPipeline(batchCommands, to: batch.endpoint)
                    return zip(batch.commands, responses).map { indexedCommand, response in
                        (
                            index: indexedCommand.index,
                            command: indexedCommand.command,
                            endpoint: batch.endpoint,
                            response: response
                        )
                    }
                }
            }

            for try await batchResponses in group {
                for batchResponse in batchResponses {
                    if case .error(let message) = batchResponse.response {
                        let redirect = RedisClusterRedirect(message: message, fallbackHost: batchResponse.endpoint.host)
                        if redirect != nil {
                            orderedResponses[batchResponse.index] = try await send(batchResponse.command)
                            continue
                        }
                    }
                    orderedResponses[batchResponse.index] = batchResponse.response
                }
            }
        }

        var responses: [RESPValue] = []
        responses.reserveCapacity(commands.count)
        for response in orderedResponses {
            guard let response else {
                throw RedisError.parseError("Missing Redis pipeline response")
            }
            responses.append(response)
        }
        return responses
    }

    func scan(cursor: String, match: String, count: Int) async throws -> RedisScanResult {
        let primaries = try await primaryEndpointsForCommand()
        let count = min(max(count, 1), 10_000)
        var scanCursor = RedisClusterScanCursor.parse(cursor)
        if scanCursor.nodeIndex >= primaries.count {
            scanCursor = RedisClusterScanCursor(nodeIndex: 0, nodeCursor: "0")
        }

        var keys: [String] = []
        var nextCursor = cursor
        var scannedCount = 0
        var attempts = 0
        let targetKeyCount = max(1, count)
        let maxAttempts = max(1, primaries.count * 3)

        repeat {
            let endpoint = primaries[scanCursor.nodeIndex]
            let response = try await sendDirect(
                ["SCAN", scanCursor.nodeCursor, "MATCH", match, "COUNT", "\(count)"],
                to: endpoint,
                asking: false
            )
            if case .error(let message) = response {
                throw RedisError.commandError(message)
            }

            let result = try RedisScanResult(response: response, scannedCount: count)
            keys.append(contentsOf: result.keys)
            scannedCount += result.keys.count

            if result.nextCursor == "0" {
                scanCursor = RedisClusterScanCursor(nodeIndex: scanCursor.nodeIndex + 1, nodeCursor: "0")
            } else {
                scanCursor = RedisClusterScanCursor(nodeIndex: scanCursor.nodeIndex, nodeCursor: result.nextCursor)
            }

            if scanCursor.nodeIndex >= primaries.count {
                nextCursor = "0"
            } else {
                nextCursor = scanCursor.storageValue
            }

            attempts += 1
        } while keys.count < targetKeyCount && nextCursor != "0" && attempts < maxAttempts

        return RedisScanResult(nextCursor: nextCursor, keys: keys, scannedCount: scannedCount)
    }

    func totalKeyCount() async throws -> Int? {
        let primaries = try await primaryEndpointsForCommand()
        var total = 0

        for endpoint in primaries {
            let keyCount = try await fetchRedisTotalKeyCount { command in
                try await self.sendDirect(command, to: endpoint, asking: false)
            }
            guard let keyCount else {
                return nil
            }
            total += keyCount
        }

        return total
    }

    func clusterNodes() async throws -> [RedisClusterNodeSummary] {
        guard isConnected else {
            throw RedisError.notConnected
        }

        var nodes = await state.nodeSummaries()
        if nodes.isEmpty {
            try await refreshTopology(preferredEndpoint: nil)
            nodes = await state.nodeSummaries()
        }
        return nodes
    }

    func send(_ args: [String], to endpoint: RedisEndpoint) async throws -> RESPValue {
        guard isConnected else {
            throw RedisError.notConnected
        }
        return try await sendDirect(args, to: endpoint, asking: false)
    }
}
