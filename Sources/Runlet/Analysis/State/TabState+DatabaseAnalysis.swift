import Foundation

extension TabState {
    // MARK: - Database Analysis

    private nonisolated static let analysisSampleLimit = 10_000
    nonisolated static let analysisProductionSampleLimit = 2_000
    private nonisolated static let analysisTopKeysCount = 50

    private struct NamespaceAgg {
        var count = 0
        var memory = 0
        var types: [String: Int] = [:]
    }

    func runDatabaseAnalysis() async {
        guard let client = activeSession, client.isConnected else { return }
        analysisGeneration += 1
        let generation = analysisGeneration
        isLoadingAnalysis = true
        analysisError = nil
        analysis = nil

        let isProduction = selectedConnection?.environment == .production
        let sampleLimit = isProduction ? Self.analysisProductionSampleLimit : Self.analysisSampleLimit
        let separator = namespaceSeparator.isEmpty ? ":" : namespaceSeparator

        // The handle IS the worker. TabState is @MainActor, so state
        // mutations below hop to the main actor automatically; the Redis
        // calls and CPU work run off the main actor because `runAnalysisWork`
        // is `nonisolated @concurrent`. Cancellation via `cancel()` is
        // delivered to this Task's `try Task.checkCancellation()` checkpoints.
        analysisTask = Task {
            try await Self.runAnalysisWork(
                client: client,
                sampleLimit: sampleLimit,
                separator: separator,
                isProduction: isProduction
            )
        }
        analysisTaskHandle = Task { @MainActor in
            guard let analysisTask else {
                isLoadingAnalysis = false
                return
            }
            do {
                let result = try await analysisTask.value
                guard !Task.isCancelled, generation == self.analysisGeneration else {
                    isLoadingAnalysis = false
                    return
                }
                analysis = result
                isLoadingAnalysis = false
            } catch is CancellationError {
                isLoadingAnalysis = false
            } catch {
                analysisError = error.localizedDescription
                isLoadingAnalysis = false
            }
        }

        await analysisTaskHandle?.value
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTaskHandle?.cancel()
        analysisTask = nil
        analysisTaskHandle = nil
    }

    /// Off-main-actor analysis body. Without `nonisolated`, this would inherit
    /// `@MainActor` from `TabState` (extension members do), putting the
    /// CPU-heavy parsing and aggregation on the main thread. `@concurrent`
    /// pins execution to the global concurrent pool: the body, its
    /// suspensions, and resumptions all stay off the main actor; the result
    /// crosses back to the main actor via the handle task in
    /// `runDatabaseAnalysis()`.
    @concurrent
    private nonisolated static func runAnalysisWork(
        client: any RedisSession,
        sampleLimit: Int,
        separator: String,
        isProduction: Bool
    ) async throws -> DatabaseAnalysis {
        var result = DatabaseAnalysis()

        // 1. Server Metrics from INFO
        let infoResult = try await client.send("INFO")
        if case .error(let message) = infoResult {
            throw RedisError.commandError(message)
        }
        if let infoStr = infoResult.string {
            let parsed = parseServerInfoForAnalysis(infoStr)
            result.serverMetrics = parsed.metrics
            result.totalKeys = parsed.totalKeys
        }

        try Task.checkCancellation()

        // 2. Scan keys for sampling (dedup + truncate: COUNT is a hint, not a cap)
        var sampledKeys: [String] = []
        var seenSampledKeys = Set<String>()
        var cursor = "0"
        var hasMore = true

        while hasMore && sampledKeys.count < sampleLimit {
            let scanResult = try await client.scan(
                cursor: cursor, match: "*", count: min(sampleLimit, 1000)
            )
            cursor = scanResult.nextCursor
            hasMore = cursor != "0"
            for key in scanResult.keys where sampledKeys.count < sampleLimit {
                if seenSampledKeys.insert(key).inserted {
                    sampledKeys.append(key)
                }
            }
        }

        result.keysSampled = sampledKeys.count
        result.isEstimate = hasMore && sampledKeys.count >= sampleLimit

        try Task.checkCancellation()

        guard !sampledKeys.isEmpty else {
            result.analyzedAt = Date()
            return result
        }

        // 3-4. Type / memory / TTL in bounded pipeline batches so a 10k sample
        // never serializes into one giant request, and cancellation lands
        // between batches instead of only at the very end.
        let samplesCount = isProduction ? "5" : "0"
        let batchSize = 500
        var typeResults: [RESPValue] = []
        var memoryResults: [RESPValue] = []
        var ttlResults: [RESPValue] = []
        for batchStart in stride(from: 0, to: sampledKeys.count, by: batchSize) {
            try Task.checkCancellation()
            let batchKeys = Array(sampledKeys[batchStart..<min(batchStart + batchSize, sampledKeys.count)])
            let typeBatch = try await client.sendPipeline(batchKeys.map { ["TYPE", $0] })
            let memoryBatch = try await client.sendPipeline(batchKeys.map { ["MEMORY", "USAGE", $0, "SAMPLES", samplesCount] })
            let ttlBatch = try await client.sendPipeline(batchKeys.map { ["TTL", $0] })
            typeResults.append(contentsOf: typeBatch)
            memoryResults.append(contentsOf: memoryBatch)
            ttlResults.append(contentsOf: ttlBatch)
        }

        var keyMemoryEntries: [KeyMemoryEntry] = []
        var typeMemory: [String: Int] = [:]
        var typeCountFinal: [String: Int] = [:]
        var memoryFailures = 0
        var expirationBuckets: [String: (count: Int, memory: Int)] = [
            "< 1h": (0, 0), "1-6h": (0, 0), "6-24h": (0, 0),
            "1-7d": (0, 0), "7-30d": (0, 0), "> 30d": (0, 0), "No expiry": (0, 0),
        ]

        for (index, key) in sampledKeys.enumerated() {
            let typeName = index < typeResults.count ? typeResults[index].string ?? "unknown" : "unknown"
            let rawMemory = index < memoryResults.count ? memoryResults[index] : nil
            let memory: Int
            if case .error(let message)? = rawMemory {
                memory = 0
                memoryFailures += 1
                if memoryFailures <= 3 {
                    AppLogger.info("MEMORY USAGE failed for key: \(message)", category: "Analysis")
                }
            } else {
                memory = rawMemory?.intValue ?? 0
            }
            let ttl = index < ttlResults.count ? ttlResults[index].intValue : nil

            typeCountFinal[typeName, default: 0] += 1
            typeMemory[typeName, default: 0] += memory
            result.totalMemory += memory

            keyMemoryEntries.append(
                KeyMemoryEntry(
                    key: key, type: typeName, memory: memory, length: 0, ttl: ttl
                ))

            // Expiration buckets
            let bucketLabel = expirationBucketLabel(for: ttl)
            var bucket = expirationBuckets[bucketLabel] ?? (0, 0)
            bucket.count += 1
            bucket.memory += memory
            expirationBuckets[bucketLabel] = bucket
        }

        // Type distribution
        for (type, count) in typeCountFinal {
            let mem = typeMemory[type] ?? 0
            result.typeDistribution[type] = TypeStats(count: count, memory: mem)
        }

        // Top keys by memory (sorted descending)
        result.topKeysByMemory = Array(
            keyMemoryEntries
                .sorted { $0.memory > $1.memory }
                .prefix(analysisTopKeysCount))

        // Namespace aggregation
        var namespaceAgg: [String: NamespaceAgg] = [:]
        for entry in keyMemoryEntries {
            let ns = namespaceFromKey(entry.key, separator: separator)
            var agg = namespaceAgg[ns] ?? NamespaceAgg()
            agg.count += 1
            agg.memory += entry.memory
            agg.types[entry.type, default: 0] += 1
            namespaceAgg[ns] = agg
        }
        result.topNamespaces =
            namespaceAgg
            .map { ns, agg in
                NamespaceStats(namespace: ns, keyCount: agg.count, totalMemory: agg.memory, types: agg.types)
            }
            .sorted { $0.totalMemory > $1.totalMemory }
            .prefix(20)
            .map { $0 }

        // Expiration summary
        result.expirationSummary =
            expirationBuckets
            .map { ExpirationBucket(label: $0.key, keyCount: $0.value.count, estimatedMemory: $0.value.memory) }
            .sorted { bucketSortIndex($0.label) < bucketSortIndex($1.label) }

        result.analyzedAt = Date()
        return result
    }

    private nonisolated static func parseServerInfoForAnalysis(_ infoStr: String) -> (metrics: ServerMetrics, totalKeys: Int) {
        var metrics = ServerMetrics()
        var totalKeys = 0
        var currentSection = ""

        for line in infoStr.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                currentSection = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let separatorIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separatorIndex])
            let valueStart = trimmed.index(after: separatorIndex)
            let value = String(trimmed[valueStart...])

            switch currentSection {
            case "Memory":
                switch key {
                case "used_memory": metrics.usedMemory = Int(value) ?? 0
                case "used_memory_human": metrics.usedMemoryHuman = value
                case "used_memory_rss": metrics.usedMemoryRSS = Int(value) ?? 0
                case "mem_fragmentation_ratio": metrics.memoryFragmentationRatio = Double(value) ?? 0
                default: break
                }
            case "Stats":
                switch key {
                case "keyspace_hits": metrics.keyspaceHits = Int(value) ?? 0
                case "keyspace_misses": metrics.keyspaceMisses = Int(value) ?? 0
                case "instantaneous_ops_per_sec": metrics.opsPerSecond = Int(value) ?? 0
                case "evicted_keys": metrics.evictedKeys = Int(value) ?? 0
                case "expired_keys": metrics.expiredKeys = Int(value) ?? 0
                default: break
                }
            case "Clients":
                switch key {
                case "connected_clients": metrics.connectedClients = Int(value) ?? 0
                case "blocked_clients": metrics.blockedClients = Int(value) ?? 0
                default: break
                }
            case "Server":
                if key == "uptime_in_seconds" {
                    metrics.uptimeInSeconds = Int(value) ?? 0
                }
            case "Keyspace":
                if key.hasPrefix("db") {
                    // db0:keys=12345,expires=234,avg_ttl=45678
                    if let keysRange = value.range(of: "keys=") {
                        let keyspaceStats = value[keysRange.upperBound...]
                        if let commaRange = keyspaceStats.firstIndex(of: ",") {
                            let keysStr = value[keysRange.upperBound..<commaRange]
                            totalKeys += Int(keysStr) ?? 0
                        }
                    }
                }
            default:
                break
            }
        }

        let totalOps = metrics.keyspaceHits + metrics.keyspaceMisses
        metrics.hitRate = totalOps > 0 ? Double(metrics.keyspaceHits) / Double(totalOps) * 100 : 0

        return (metrics, totalKeys)
    }

    private nonisolated static func expirationBucketLabel(for ttl: Int?) -> String {
        guard let ttl, ttl > 0 else { return "No expiry" }
        switch ttl {
        case ..<3600: return "< 1h"
        case ..<21600: return "1-6h"
        case ..<86400: return "6-24h"
        case ..<604800: return "1-7d"
        case ..<2_592_000: return "7-30d"
        default: return "> 30d"
        }
    }

    private nonisolated static func bucketSortIndex(_ label: String) -> Int {
        switch label {
        case "< 1h": return 0
        case "1-6h": return 1
        case "6-24h": return 2
        case "1-7d": return 3
        case "7-30d": return 4
        case "> 30d": return 5
        case "No expiry": return 6
        default: return 7
        }
    }

    private nonisolated static func namespaceFromKey(_ key: String, separator: String) -> String {
        guard !separator.isEmpty else { return "default" }
        if let range = key.range(of: separator) {
            return String(key[..<range.lowerBound])
        }
        return "default"
    }
}
