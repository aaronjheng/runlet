import Foundation

// MARK: - Add Key

/// Creation flow for new keys from the Keys pane's Add-Key sheet: existence
/// check, per-type validation and creation (string/list/hash/set/zset), then
/// selection of the created key.
extension KeysView {
    func addKey(name: String, type: String, value: String) async {
        guard let client = tab.activeSession else { return }
        do {
            let existsResult = try await client.send("EXISTS", name)
            try throwIfRedisError(existsResult)
            guard existsResult.intValue == 0 else {
                throw RedisError.commandError("Key \"\(name)\" already exists")
            }

            switch type {
            case "string":
                let result = try await client.send("SET", name, value, "NX")
                try throwIfRedisError(result)
                guard result.string != nil else {
                    throw RedisError.commandError("Key \"\(name)\" already exists")
                }
            case "list":
                let values = value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                guard !values.isEmpty else {
                    throw RedisError.commandError("List key requires at least one value")
                }
                let result = try await client.send(["RPUSH", name] + values)
                try throwIfRedisError(result)
            case "hash":
                var args = ["HSET", name]
                for (offset, line) in value.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        args.append(String(parts[0]))
                        args.append(String(parts[1]))
                    } else {
                        // Blank form rows produce a bare ":" — skip those, but never
                        // silently drop a line the user actually typed.
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, trimmed != ":" {
                            throw RedisError.commandError(
                                "Line \(offset + 1) needs \"field:value\" format")
                        }
                    }
                }
                guard args.count > 2 else {
                    throw RedisError.commandError("Hash key requires at least one field")
                }
                let result = try await client.send(args)
                try throwIfRedisError(result)
            case "set":
                let members = value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                guard !members.isEmpty else {
                    throw RedisError.commandError("Set key requires at least one member")
                }
                let result = try await client.send(["SADD", name] + members)
                try throwIfRedisError(result)
            case "zset":
                var args = ["ZADD", name, "NX"]
                for (offset, line) in value.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        args.append(String(parts[0]))
                        args.append(String(parts[1]))
                    } else {
                        // Blank form rows produce a bare ":" — skip those, but never
                        // silently drop a line the user actually typed.
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, trimmed != ":" {
                            throw RedisError.commandError(
                                "Line \(offset + 1) needs \"score:member\" format")
                        }
                    }
                }
                guard args.count > 3 else {
                    throw RedisError.commandError("Sorted set key requires at least one member")
                }
                let result = try await client.send(args)
                try throwIfRedisError(result)
            default:
                let result = try await client.send("SET", name, value, "NX")
                try throwIfRedisError(result)
                guard result.string != nil else {
                    throw RedisError.commandError("Key \"\(name)\" already exists")
                }
            }
            tab.connectionError = nil
            let createdKey = tab.insertCreatedKey(name: name, type: type)
            let isCreatedKeyVisible = tab.keyTypeFilter.isEmpty || tab.keyTypeFilter == type
            if let createdKey, isCreatedKeyVisible {
                tab.selectedKey = createdKey
                keyListScrollTarget = createdKey.key
            }
        } catch {
            tab.connectionError = error.localizedDescription
        }
    }
}
