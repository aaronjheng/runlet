import Foundation

extension TabState {
    func reportKeyOperationError(_ error: Error) {
        let message = error.localizedDescription
        connectionError = message
        keyDetailError = message
        keyDetail = "Error: \(message)"
    }

    func deleteKey(_ entry: RedisKeyEntry) async {
        guard let client = activeSession else { return }
        do {
            let result = try await client.send("DEL", entry.key)
            try throwIfRedisError(result)
            if (result.intValue ?? 0) > 0 {
                noteKeyDeleted()
            }
            keys.removeAll { $0.key == entry.key }
            if selectedKey?.key == entry.key {
                clearSelectedKeyDetail()
            }
        } catch {
            reportKeyOperationError(error)
        }
    }

    func renameKey(old: String, new: String) async {
        guard let client = activeSession else { return }
        do {
            let result = try await client.send("RENAMENX", old, new)
            try throwIfRedisError(result)
            guard result.intValue != 0 else {
                throw RedisError.commandError("Key \"\(new)\" already exists")
            }
            keys.removeAll { $0.key == old }
            let newEntry = RedisKeyEntry(key: new, type: "", ttl: nil, size: nil)
            keys.insert(newEntry, at: 0)
            if selectedKey?.key == old {
                selectedKey = newEntry
                await refreshSelectedKey()
            } else {
                await scanKeys(reset: true)
            }
        } catch {
            reportKeyOperationError(error)
        }
    }

    // MARK: - Key Editing

    func updateKeyTTL(_ entry: RedisKeyEntry, ttl: Int) async {
        guard let client = activeSession else { return }

        do {
            if ttl == -1 {
                let currentTTL = try? await client.send("TTL", entry.key)
                if (currentTTL?.intValue ?? -1) > 0 {
                    let result = try await client.send("PERSIST", entry.key)
                    try throwIfRedisError(result)
                }
                entry.ttl = -1
            } else {
                let result = try await client.send("EXPIRE", entry.key, "\(ttl)")
                try throwIfRedisError(result)
                if result.intValue == 0 || ttl == 0 {
                    if ttl == 0 {
                        noteKeyDeleted()
                    }
                    keys.removeAll { $0.key == entry.key }
                    if selectedKey?.key == entry.key {
                        clearSelectedKeyDetail()
                    }
                    return
                }
                entry.ttl = ttl
            }
        } catch {
            reportKeyOperationError(error)
        }
    }

    func updateStringValue(key: String, value: String) async {
        guard let client = activeSession else { return }
        do {
            let ttlResult = try await client.send("TTL", key)
            try throwIfRedisError(ttlResult)
            let ttl = ttlResult.intValue ?? -1

            let setResult = try await client.send("SET", key, value, "XX")
            try throwIfRedisError(setResult)
            guard setResult.string != nil else {
                throw RedisError.commandError("Key \"\(key)\" no longer exists")
            }

            if ttl > 0 {
                let expireResult = try await client.send("EXPIRE", key, "\(ttl)")
                try throwIfRedisError(expireResult)
            }
        } catch {
            reportKeyOperationError(error)
        }
    }

    func addHashField(key: String, field: String, value: String) async {
        await addHashFields(key: key, pairs: [(field: field, value: value)])
    }

    func addHashFields(key: String, pairs: [(field: String, value: String)]) async {
        guard !pairs.isEmpty, let client = activeSession else { return }
        var args = ["HSET", key]
        for pair in pairs {
            args.append(pair.field)
            args.append(pair.value)
        }
        do {
            let result = try await client.send(args)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func updateHashField(key: String, field: String, value: String) async {
        await addHashField(key: key, field: field, value: value)
    }

    func deleteHashField(key: String, field: String) async {
        guard let client = activeSession else { return }
        do {
            let result = try await client.send("HDEL", key, field)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func addListElements(key: String, values: [String], tail: Bool = false) async {
        guard !values.isEmpty, let client = activeSession else { return }
        // LPUSHX places the last argument at the head, so a head push reverses
        // the batch to keep the entered order from the head down.
        let ordered = tail ? values : values.reversed()
        do {
            let result = try await client.send([tail ? "RPUSHX" : "LPUSHX", key] + ordered)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func updateListElement(key: String, index: Int, value: String) async {
        guard let client = activeSession else { return }
        do {
            let result = try await client.send("LSET", key, "\(index)", value)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func deleteListElement(key: String, index: Int) async {
        guard let client = activeSession else { return }
        let marker = "__runlet_delete_\(UUID().uuidString)__"
        do {
            let setResult = try await client.send("LSET", key, "\(index)", marker)
            try throwIfRedisError(setResult)
            let removeResult = try await client.send("LREM", key, "1", marker)
            try throwIfRedisError(removeResult)
        } catch {
            reportKeyOperationError(error)
        }
    }

    /// Appends values to an array. Entries without an explicit index append
    /// sequentially from `ARINFO`'s `len` (max index + 1), not `ARNEXT`, because
    /// the insert cursor only tracks `ARINSERT`/`ARRING` and would be 0 for
    /// arrays built via `ARSET`. All entries land in a single `ARMSET`.
    func addArrayElements(key: String, entries: [(index: Int?, value: String)]) async {
        guard !entries.isEmpty, let client = activeSession else { return }
        do {
            var nextAppendIndex: Int?
            if entries.contains(where: { $0.index == nil }) {
                let infoResult = try await client.send("ARINFO", key)
                try throwIfRedisError(infoResult)
                let info = Dictionary(
                    uniqueKeysWithValues: infoResult.keyValuePairs.compactMap { pair -> (String, Int)? in
                        guard let name = pair.key.string, let value = pair.value.intValue else { return nil }
                        return (name, value)
                    })
                nextAppendIndex = info["len"] ?? 0
            }

            var args = ["ARMSET", key]
            for entry in entries {
                let index: Int
                if let explicit = entry.index {
                    index = explicit
                } else {
                    index = nextAppendIndex ?? 0
                    nextAppendIndex = index + 1
                }
                args.append("\(index)")
                args.append(entry.value)
            }
            let result = try await client.send(args)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func updateArrayElement(key: String, index: Int, value: String) async {
        guard let client = activeSession else { return }
        do {
            let result = try await client.send("ARMSET", key, "\(index)", value)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func deleteArrayElement(key: String, index: Int) async {
        guard let client = activeSession else { return }
        do {
            let result = try await client.send("ARDEL", key, "\(index)")
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func addSetMembers(key: String, members: [String]) async {
        guard !members.isEmpty, let client = activeSession else { return }
        do {
            let result = try await client.send(["SADD", key] + members)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func deleteSetMember(key: String, member: String) async {
        guard let client = activeSession else { return }
        do {
            let result = try await client.send("SREM", key, member)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func addZSetMembers(key: String, members: [(score: String, member: String)]) async {
        guard !members.isEmpty, let client = activeSession else { return }
        var args = ["ZADD", key, "NX"]
        for member in members {
            args.append(member.score)
            args.append(member.member)
        }
        do {
            let result = try await client.send(args)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func updateZSetScore(key: String, member: String, score: String) async {
        guard let client = activeSession else { return }
        do {
            let currentScore = try await client.send("ZSCORE", key, member)
            try throwIfRedisError(currentScore)
            guard currentScore.string != nil else {
                throw RedisError.commandError("Sorted set member no longer exists")
            }

            let result = try await client.send("ZADD", key, "XX", "CH", score, member)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }

    func deleteZSetMember(key: String, member: String) async {
        guard let client = activeSession else { return }
        do {
            let result = try await client.send("ZREM", key, member)
            try throwIfRedisError(result)
        } catch {
            reportKeyOperationError(error)
        }
    }
}
