// Needed for `fnmatch` (POSIX pattern matching) used in `keyMatchesCurrentFilter`.
import Darwin
import Foundation

extension TabState {
    // MARK: - Keys

    /// Memoized namespace tree for the current keys/filter/separator.
    func namespaceTree(for entries: [RedisKeyEntry]) -> KeyNamespaceTree {
        if let cached = keyNamespaceTreeCache, !entries.isEmpty { return cached }
        let tree = KeyNamespaceTree(entries: entries, separator: namespaceSeparator)
        keyNamespaceTreeCache = tree
        return tree
    }

    func scanKeys(reset: Bool = false) async {
        if isScanningKeysRequest {
            pendingResetScan = pendingResetScan || reset
            if !reset {
                pendingLoadMore = true
            }
            return
        }

        guard let client = activeSession, client.isConnected else {
            isLoadingKeys = false
            return
        }

        isScanningKeysRequest = true
        if reset {
            scanCursor = "0"
            keys = []
            clearSelectedKeyDetail()
            hasMoreKeys = true
            keyTotalCount = nil
            keyScannedCount = 0
            keyScanIterationCount = 0
            keyScanLimitReached = false
        }
        isLoadingKeys = true

        let isPattern = keyFilter.contains("*") || keyFilter.contains("?") || keyFilter.contains("[")

        do {
            if reset {
                await refreshKeyTotalCount(using: client)
            }

            if !isPattern {
                let typeResult = try? await client.send("TYPE", keyFilter)
                if let typeName = typeResult?.string, typeName != "none" {
                    let entry = RedisKeyEntry(key: keyFilter, type: typeName, ttl: nil, size: nil)
                    keys = [entry]
                    loadKeyMetadata(for: [entry])
                } else {
                    keys = []
                    clearSelectedKeyDetail()
                }
                hasMoreKeys = false
                keyScannedCount = keyTotalCount ?? keys.count
            } else {
                let scanAll = keyFilter != "*"
                var iterations = 0
                let maxIterations = scanAll ? keyPatternScanIterationLimit : 1
                // Incremental dedup set: rebuilding it from `keys` each iteration
                // was O(N²) on large keyspaces.
                var seenKeys = Set(keys.map { $0.key })
                repeat {
                    try Task.checkCancellation()
                    let result = try await client.scan(cursor: scanCursor, match: keyFilter, count: keyScanCount)
                    scanCursor = result.nextCursor
                    hasMoreKeys = scanCursor != "0"
                    let newKeyNames = result.keys
                    keyScannedCount += result.scannedCount
                    normalizeKeyScanProgress()
                    let newEntries = newKeyNames.compactMap { keyName -> RedisKeyEntry? in
                        guard seenKeys.insert(keyName).inserted else { return nil }
                        return RedisKeyEntry(key: keyName, type: "", ttl: nil, size: nil)
                    }
                    keys.append(contentsOf: newEntries)
                    iterations += 1
                    keyScanIterationCount += 1
                } while hasMoreKeys && iterations < maxIterations && (scanAll || keys.isEmpty)
                keyScanLimitReached = hasMoreKeys && iterations >= maxIterations
                normalizeKeyScanProgress()
            }
        } catch {
            connectionError = error.localizedDescription
        }

        let shouldRestart = pendingResetScan
        let shouldLoadMore = pendingLoadMore
        pendingResetScan = false
        pendingLoadMore = false
        isScanningKeysRequest = false
        isLoadingKeys = false

        if isPattern {
            let entriesNeedingMetadata = keys.filter { entry in
                entry.type.isEmpty
            }
            loadKeyMetadata(for: entriesNeedingMetadata)
        }

        if shouldRestart {
            await scanKeys(reset: true)
        } else if shouldLoadMore {
            await scanKeys()
        }
    }
    @discardableResult
    func insertCreatedKey(name: String, type: String) -> RedisKeyEntry? {
        noteKeyCreated()
        guard keyMatchesCurrentFilter(name) else { return nil }

        let entry = RedisKeyEntry(key: name, type: type, ttl: nil, size: nil)
        if isCurrentKeyFilterPattern {
            keys.removeAll { $0.key == name }
            keys.insert(entry, at: 0)
            keyScannedCount = max(keyScannedCount, keys.count)
        } else {
            keys = [entry]
            scanCursor = "0"
            hasMoreKeys = false
            keyScannedCount = keyTotalCount ?? 1
            keyScanIterationCount = 0
            keyScanLimitReached = false
        }
        normalizeKeyScanProgress()

        loadKeyMetadata(for: [entry])
        return entry
    }

    private var isCurrentKeyFilterPattern: Bool {
        keyFilter.contains("*") || keyFilter.contains("?") || keyFilter.contains("[")
    }

    private func keyMatchesCurrentFilter(_ keyName: String) -> Bool {
        let filter = keyFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = filter.isEmpty ? "*" : filter
        guard pattern.contains("*") || pattern.contains("?") || pattern.contains("[") else {
            return pattern == keyName
        }
        return fnmatch(pattern, keyName, 0) == 0
    }

    private func refreshKeyTotalCount(using client: any RedisSession) async {
        do {
            keyTotalCount = try await client.totalKeyCount()
        } catch {
            keyTotalCount = nil
            AppLogger.debug("failed to load key total: \(error)", category: "Keys")
        }
    }

    private func normalizeKeyScanProgress() {
        guard let total = keyTotalCount else { return }
        if !hasMoreKeys || keyScannedCount > total {
            keyScannedCount = total
        }
    }

    private func noteKeyCreated() {
        if let total = keyTotalCount {
            keyTotalCount = total + 1
        }
        keyScannedCount += 1
        normalizeKeyScanProgress()
    }

    func noteKeyDeleted() {
        if let total = keyTotalCount {
            keyTotalCount = max(0, total - 1)
        }
        keyScannedCount = max(0, keyScannedCount - 1)
        normalizeKeyScanProgress()
    }

    private func loadKeyMetadata(for entries: [RedisKeyEntry]) {
        guard let client = activeSession, client.isConnected else { return }
        guard !entries.isEmpty else { return }
        let generation = connectGeneration

        Task { @MainActor in
            do {
                for batchStart in stride(from: 0, to: entries.count, by: keyMetadataPipelineBatchSize) {
                    try Task.checkCancellation()
                    guard generation == self.connectGeneration else { return }
                    let batchEnd = min(batchStart + keyMetadataPipelineBatchSize, entries.count)
                    let batchEntries = Array(entries[batchStart..<batchEnd])
                    let commands = batchEntries.map { entry in
                        ["TYPE", entry.key]
                    }

                    let metadataResults = try await client.sendPipeline(commands)
                    guard generation == self.connectGeneration else { return }
                    applyMetadataResults(metadataResults, to: batchEntries)
                }
            } catch is CancellationError {
                // A newer scan superseded this metadata pass
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }

    private func applyMetadataResults(_ results: [RESPValue], to entries: [RedisKeyEntry]) {
        for (entryIndex, entry) in entries.enumerated() {
            guard entryIndex < results.count else { continue }

            if let typeName = results[entryIndex].string {
                if typeName == "none" {
                    keys.removeAll { $0.key == entry.key }
                    if selectedKey?.key == entry.key {
                        clearSelectedKeyDetail()
                    }
                    continue
                }
                entry.type = typeName
            }

            if selectedKey?.key == entry.key {
                keyType = entry.type
            }
        }
    }
}
