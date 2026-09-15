import Foundation

extension TabState {
    func clearSelectedKeyDetail() {
        selectedKey = nil
        keyDetail = ""
        keyDetailRows = []
        keyType = ""
        valueSize = nil
        keyDetailTotalCount = nil
        keyDetailError = nil
        keyDetailTruncated = false
        keyDetailOffset = 0
        keyDetailCursor = "0"
        keyDetailHasMoreRows = false
        keyDetailSearchText = ""
        keyDetailLastRefreshedAt = nil
        isLoadingDetail = false
    }
    func selectKey(_ entry: RedisKeyEntry) async {
        selectedKey = entry
        keyDetailSearchText = ""
        keyDetailOrder = .ascending
        resetKeyDetailPaging(clearRows: true)
        keyDetailGeneration += 1
        await loadSelectedKeyDetail(append: false)
    }

    func loadMoreSelectedKeyDetailRows() async {
        guard keyDetailHasMoreRows, !isLoadingDetail else { return }
        await loadSelectedKeyDetail(append: true)
    }

    func searchSelectedKeyDetail(_ searchText: String) async {
        keyDetailSearchText = searchText
        resetKeyDetailPaging(clearRows: true)
        keyDetailGeneration += 1
        await loadSelectedKeyDetail(append: false)
    }

    func updateSelectedKeyOrder(_ order: KeyDetailOrder) async {
        guard keyDetailOrder != order else { return }
        keyDetailOrder = order
        resetKeyDetailPaging(clearRows: true)
        keyDetailGeneration += 1
        await loadSelectedKeyDetail(append: false)
    }

    private func loadSelectedKeyDetail(append: Bool) async {
        let token = keyDetailGeneration
        guard let entry = selectedKey else { return }
        guard let client = activeSession else { return }

        isLoadingDetail = true
        keyDetailError = nil
        if !append {
            keyDetail = ""
            keyDetailRows = []
            valueSize = nil
            keyDetailTotalCount = nil
        }

        do {
            let typeResult = try await client.send("TYPE", entry.key)
            try throwIfRedisError(typeResult)
            guard token == keyDetailGeneration else { return }
            keyType = typeResult.string ?? "string"
            guard keyType != "none" else {
                keys.removeAll { $0.key == entry.key }
                clearSelectedKeyDetail()
                return
            }
            entry.type = keyType
            keyDetailTotalCount = await loadLength(for: entry.key, type: keyType, using: client)
            guard token == keyDetailGeneration else { return }
            entry.length = keyDetailTotalCount

            switch keyType {
            case "string":
                let lengthResult = try await client.send("STRLEN", entry.key)
                try throwIfRedisError(lengthResult)
                let stringLength = lengthResult.intValue ?? 0
                let isOversized = stringLength > stringDetailTruncationLimit
                if isOversized {
                    let partial = try await client.send("GETRANGE", entry.key, "0", "\(stringDetailTruncationLimit - 1)")
                    try throwIfRedisError(partial)
                    guard token == keyDetailGeneration else { return }
                    keyDetail = partial.string ?? ""
                    keyDetailHasMoreRows = false
                    keyDetailTruncated = true
                } else {
                    let value = try await client.send("GET", entry.key)
                    try throwIfRedisError(value)
                    guard token == keyDetailGeneration else { return }
                    keyDetail = value.string ?? "(nil)"
                    keyDetailHasMoreRows = false
                    keyDetailTruncated = false
                }
            case "list":
                try await loadListDetail(key: entry.key, append: append, using: client, token: token)
            case "hash":
                try await loadHashDetail(key: entry.key, append: append, using: client, token: token)
            case "set":
                try await loadSetDetail(key: entry.key, append: append, using: client, token: token)
            case "zset":
                try await loadZSetDetail(key: entry.key, append: append, using: client, token: token)
            default:
                let lengthResult = try await client.send("STRLEN", entry.key)
                try throwIfRedisError(lengthResult)
                let stringLength = lengthResult.intValue ?? 0
                let isOversized = stringLength > stringDetailTruncationLimit
                if isOversized {
                    let partial = try await client.send("GETRANGE", entry.key, "0", "\(stringDetailTruncationLimit - 1)")
                    try throwIfRedisError(partial)
                    guard token == keyDetailGeneration else { return }
                    keyDetail = partial.string ?? ""
                    keyDetailTruncated = true
                } else {
                    let value = try await client.send("GET", entry.key)
                    try throwIfRedisError(value)
                    guard token == keyDetailGeneration else { return }
                    keyDetail = value.string ?? "(nil)"
                    keyDetailTruncated = false
                }
                keyDetailHasMoreRows = false
            }

            guard token == keyDetailGeneration else { return }
            await refreshMetadata(for: entry, using: client)
            guard token == keyDetailGeneration else { return }
            keyDetailLastRefreshedAt = Date()
        } catch {
            if token == keyDetailGeneration {
                reportKeyOperationError(error)
            }
        }
        if token == keyDetailGeneration {
            isLoadingDetail = false
        }
    }

    private func resetKeyDetailPaging(clearRows: Bool) {
        keyDetailOffset = 0
        keyDetailCursor = "0"
        keyDetailHasMoreRows = false
        keyDetailError = nil
        if clearRows {
            keyDetailRows = []
            keyDetail = ""
        }
    }

    private func refreshMetadata(for entry: RedisKeyEntry, using client: any RedisSession) async {
        do {
            let results = try await client.sendPipeline([
                ["TTL", entry.key],
                ["MEMORY", "USAGE", entry.key, "SAMPLES", "0"],
            ])
            entry.ttl = results.first?.intValue
            entry.size = results.dropFirst().first?.intValue
            valueSize = entry.size
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func loadLength(for key: String, type: String, using client: any RedisSession) async -> Int? {
        let command: [String]?
        switch type {
        case "string": command = ["STRLEN", key]
        case "list": command = ["LLEN", key]
        case "hash": command = ["HLEN", key]
        case "set": command = ["SCARD", key]
        case "zset": command = ["ZCARD", key]
        default: command = nil
        }
        guard let command, let result = try? await client.send(command) else { return nil }
        return result.intValue
    }

    private func loadListDetail(key: String, append: Bool, using client: any RedisSession, token: Int) async throws {
        if keyDetailOrder == .descending, let keyDetailTotalCount {
            try await loadReversedListDetail(key: key, totalCount: keyDetailTotalCount, append: append, using: client, token: token)
            return
        }

        let start = append ? keyDetailOffset : 0
        let stop = start + keyDetailPageSize - 1
        let value = try await client.send("LRANGE", key, "\(start)", "\(stop)")
        try throwIfRedisError(value)
        guard token == keyDetailGeneration else { return }
        let rows = value.arrayValues.enumerated().compactMap { index, value -> (String, String)? in
            guard let value else { return nil }
            return ("\(start + index)", value.string ?? value.displayString)
        }
        if append {
            keyDetailRows.append(contentsOf: rows)
        } else {
            keyDetailRows = rows
        }
        keyDetailOffset = start + rows.count
        if let keyDetailTotalCount {
            keyDetailHasMoreRows = keyDetailOffset < keyDetailTotalCount
        } else {
            keyDetailHasMoreRows = rows.count == keyDetailPageSize
        }
    }

    /// Loads a list window from the tail upward so the Index column can be
    /// shown in descending order. Redis has no reversed range command, so the
    /// window is fetched ascending with `LRANGE` and reversed locally while
    /// keeping the real indices.
    private func loadReversedListDetail(
        key: String,
        totalCount: Int,
        append: Bool,
        using client: any RedisSession,
        token: Int
    ) async throws {
        let loadedCount = append ? keyDetailOffset : 0
        let high = totalCount - 1 - loadedCount
        let low = max(high - keyDetailPageSize + 1, 0)
        guard low <= high else {
            keyDetailHasMoreRows = false
            return
        }
        let value = try await client.send("LRANGE", key, "\(low)", "\(high)")
        try throwIfRedisError(value)
        guard token == keyDetailGeneration else { return }
        let rows = value.arrayValues.enumerated().compactMap { offset, value -> (String, String)? in
            guard let value else { return nil }
            return ("\(high - offset)", value.string ?? value.displayString)
        }
        if append {
            keyDetailRows.append(contentsOf: rows)
        } else {
            keyDetailRows = rows
        }
        keyDetailOffset = loadedCount + rows.count
        keyDetailHasMoreRows = keyDetailOffset < totalCount
    }

    private func loadHashDetail(key: String, append: Bool, using client: any RedisSession, token: Int) async throws {
        var args = ["HSCAN", key, append ? keyDetailCursor : "0"]
        if let pattern = keyDetailMatchPattern {
            args.append(contentsOf: ["MATCH", pattern])
        }
        args.append(contentsOf: ["COUNT", "\(keyDetailPageSize)"])

        let response = try await client.send(args)
        let result = try parseScanValues(response, context: "HSCAN")
        guard token == keyDetailGeneration else { return }
        let rows = keyValueRows(from: result.values)
        if append {
            keyDetailRows.append(contentsOf: rows)
        } else {
            keyDetailRows = rows
        }
        keyDetailCursor = result.nextCursor
        keyDetailHasMoreRows = result.nextCursor != "0"
    }

    private func loadSetDetail(key: String, append: Bool, using client: any RedisSession, token: Int) async throws {
        var args = ["SSCAN", key, append ? keyDetailCursor : "0"]
        if let pattern = keyDetailMatchPattern {
            args.append(contentsOf: ["MATCH", pattern])
        }
        args.append(contentsOf: ["COUNT", "\(keyDetailPageSize)"])

        let response = try await client.send(args)
        let result = try parseScanValues(response, context: "SSCAN")
        guard token == keyDetailGeneration else { return }
        let baseIndex = append ? keyDetailRows.count : 0
        let rows = result.values.enumerated().compactMap { index, value -> (String, String)? in
            guard let value else { return nil }
            return ("[\(baseIndex + index)]", value.string ?? value.displayString)
        }
        if append {
            keyDetailRows.append(contentsOf: rows)
        } else {
            keyDetailRows = rows
        }
        keyDetailCursor = result.nextCursor
        keyDetailHasMoreRows = result.nextCursor != "0"
    }

    private func loadZSetDetail(key: String, append: Bool, using client: any RedisSession, token: Int) async throws {
        if keyDetailMatchPattern != nil {
            try await loadScannedZSetDetail(key: key, append: append, using: client, token: token)
            return
        }

        let start = append ? keyDetailOffset : 0
        let stop = start + keyDetailPageSize - 1
        let command = keyDetailOrder == .descending ? "ZREVRANGE" : "ZRANGE"
        let value = try await client.send(command, key, "\(start)", "\(stop)", "WITHSCORES")
        try throwIfRedisError(value)
        guard token == keyDetailGeneration else { return }
        let rows = scoredRows(from: value.arrayValues)
        if append {
            keyDetailRows.append(contentsOf: rows)
        } else {
            keyDetailRows = rows
        }
        keyDetailOffset = start + rows.count
        if let keyDetailTotalCount {
            keyDetailHasMoreRows = keyDetailOffset < keyDetailTotalCount
        } else {
            keyDetailHasMoreRows = rows.count == keyDetailPageSize
        }
    }

    private func loadScannedZSetDetail(key: String, append: Bool, using client: any RedisSession, token: Int) async throws {
        var args = ["ZSCAN", key, append ? keyDetailCursor : "0"]
        if let pattern = keyDetailMatchPattern {
            args.append(contentsOf: ["MATCH", pattern])
        }
        args.append(contentsOf: ["COUNT", "\(keyDetailPageSize)"])

        let response = try await client.send(args)
        let result = try parseScanValues(response, context: "ZSCAN")
        guard token == keyDetailGeneration else { return }
        let rows = scoredRows(from: result.values)
        if append {
            keyDetailRows.append(contentsOf: rows)
        } else {
            keyDetailRows = rows
        }
        keyDetailCursor = result.nextCursor
        keyDetailHasMoreRows = result.nextCursor != "0"
    }

    private var keyDetailMatchPattern: String? {
        let trimmed = keyDetailSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("[") {
            return trimmed
        }
        return "*\(trimmed)*"
    }

    private func parseScanValues(
        _ response: RESPValue,
        context: String
    ) throws -> (nextCursor: String, values: [RESPValue?]) {
        try throwIfRedisError(response)
        let values = response.arrayValues
        guard values.count >= 2, let cursor = values[0]?.string else {
            throw RedisError.parseError("Unexpected \(context) response")
        }
        return (nextCursor: cursor, values: values[1]?.arrayValues ?? [])
    }

    private func keyValueRows(from values: [RESPValue?]) -> [(String, String)] {
        var rows: [(String, String)] = []
        for value in values {
            guard let value else { continue }
            if case .array(let pair) = value, pair.count >= 2 {
                let key = pair[0]?.string ?? pair[0]?.displayString ?? ""
                let val = pair[1]?.string ?? pair[1]?.displayString ?? ""
                rows.append((key, val))
            }
        }
        if !rows.isEmpty { return rows }
        var itemIndex = 0
        while itemIndex + 1 < values.count {
            guard let key = values[itemIndex] else {
                itemIndex += 2
                continue
            }
            let value = values[itemIndex + 1]
            rows.append((key.string ?? key.displayString, value?.string ?? value?.displayString ?? ""))
            itemIndex += 2
        }
        return rows
    }

    private func scoredRows(from values: [RESPValue?]) -> [(String, String)] {
        var rows: [(String, String)] = []
        for value in values {
            guard let value else { continue }
            if case .array(let pair) = value, pair.count >= 2 {
                let member = pair[0]?.string ?? pair[0]?.displayString ?? ""
                let score = pair[1]?.string ?? pair[1]?.displayString ?? ""
                rows.append((score, member))
            }
        }
        if !rows.isEmpty { return rows }
        var itemIndex = 0
        while itemIndex + 1 < values.count {
            let member = values[itemIndex]?.string ?? values[itemIndex]?.displayString ?? ""
            let score = values[itemIndex + 1]?.string ?? values[itemIndex + 1]?.displayString ?? ""
            rows.append((score, member))
            itemIndex += 2
        }
        return rows
    }
    func refreshSelectedKey() async {
        guard let selectedKey else { return }
        resetKeyDetailPaging(clearRows: true)
        await loadSelectedKeyDetail(append: false)
    }
}
