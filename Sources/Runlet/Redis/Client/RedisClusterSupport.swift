import Foundation

// MARK: - Cluster Support Types

/// Pure helpers behind `RedisClusterClient`: slot ranges, cross-node scan
/// cursors, MOVED/ASK redirect parsing, per-command key extraction, retry
/// classification, and CRC16/hashtag slot computation.
struct RedisClusterSlotRange: Sendable {
    let start: Int
    let end: Int
    let primary: RedisEndpoint
    let replicas: [RedisEndpoint]
}

struct RedisClusterScanCursor: Sendable {
    let nodeIndex: Int
    let nodeCursor: String

    var storageValue: String {
        "cluster:\(nodeIndex):\(nodeCursor)"
    }

    static func parse(_ value: String) -> RedisClusterScanCursor {
        guard value.hasPrefix("cluster:") else {
            return RedisClusterScanCursor(nodeIndex: 0, nodeCursor: value.isEmpty ? "0" : value)
        }

        let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let index = Int(parts[1]) else {
            return RedisClusterScanCursor(nodeIndex: 0, nodeCursor: "0")
        }

        return RedisClusterScanCursor(nodeIndex: index, nodeCursor: parts[2])
    }
}

enum RedisClusterRedirectKind: Sendable {
    case moved
    case ask
}

struct RedisClusterRedirect: Sendable {
    let kind: RedisClusterRedirectKind
    let slot: Int
    let endpoint: RedisEndpoint

    init?(message: String, fallbackHost: String) {
        let parts = message.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let slot = Int(parts[1]) else { return nil }

        switch parts[0].uppercased() {
        case "MOVED":
            kind = .moved
        case "ASK":
            kind = .ask
        default:
            return nil
        }

        guard let endpoint = RedisEndpoint.parse(parts[2]) else { return nil }
        self.slot = slot
        if endpoint.host.isEmpty {
            self.endpoint = RedisEndpoint(host: fallbackHost, port: endpoint.port)
        } else {
            self.endpoint = endpoint
        }
    }
}

enum RedisClusterCommandKeys {
    private static let noKeyCommands: Set<String> = [
        "AUTH", "CLIENT", "CLUSTER", "COMMAND", "CONFIG", "DBSIZE", "ECHO", "HELLO", "INFO",
        "LASTSAVE", "PING", "QUIT", "READONLY", "READWRITE", "ROLE", "SCAN", "SELECT",
        "SLOWLOG", "TIME",
    ]

    private static let firstKeyCommands: Set<String> = [
        "APPEND", "BITCOUNT", "BITFIELD", "BITPOS", "DECR", "DECRBY", "DUMP",
        "EXPIRE", "EXPIREAT", "GET", "GETBIT", "GETDEL", "GETEX", "GETRANGE", "GETSET",
        "HDEL", "HEXISTS", "HGET", "HGETALL", "HINCRBY", "HINCRBYFLOAT", "HKEYS", "HLEN",
        "HMGET", "HMSET", "HRANDFIELD", "HSCAN", "HSET", "HSETNX", "HSTRLEN", "HVALS",
        "INCR", "INCRBY", "INCRBYFLOAT", "LINDEX", "LINSERT", "LLEN", "LMOVE", "LPOP",
        "LPOS", "LPUSH", "LPUSHX", "LRANGE", "LREM", "LSET", "LTRIM", "OBJECT", "PERSIST",
        "PEXPIRE", "PEXPIREAT", "PFADD", "PFCOUNT", "PFMERGE", "PSETEX", "PTTL", "RESTORE",
        "RPOP", "RPOPLPUSH", "RPUSH", "RPUSHX", "SADD", "SCARD", "SDIFF", "SET", "SETBIT",
        "SETEX", "SETNX", "SETRANGE", "SINTER", "SISMEMBER", "SMEMBERS", "SMISMEMBER",
        "SMOVE", "SORT", "SPOP", "SRANDMEMBER", "SREM", "SSCAN", "STRLEN", "TTL", "TYPE",
        "WATCH", "ZADD", "ZCARD", "ZCOUNT", "ZINCRBY", "ZLEXCOUNT", "ZPOPMAX", "ZPOPMIN",
        "ZRANDMEMBER", "ZRANGE", "ZRANGEBYLEX", "ZRANGEBYSCORE", "ZRANGESTORE", "ZRANK",
        "ZREM", "ZREMRANGEBYLEX", "ZREMRANGEBYRANK", "ZREMRANGEBYSCORE", "ZREVRANGE",
        "ZREVRANGEBYLEX", "ZREVRANGEBYSCORE", "ZREVRANK", "ZSCAN", "ZSCORE",
    ]

    private static let allKeyCommands: Set<String> = [
        "DEL", "EXISTS", "MGET", "TOUCH", "UNLINK",
    ]

    private static let blockingMultiKeyWithTimeoutCommands: Set<String> = [
        "BLMOVE", "BLPOP", "BRPOP", "BRPOPLPUSH", "BZPOPMAX", "BZPOPMIN",
    ]

    static func keys(in args: [String]) throws -> [String] {
        guard let command = args.first?.uppercased() else { return [] }

        if noKeyCommands.contains(command) {
            return []
        }

        if firstKeyCommands.contains(command) {
            return args.count > 1 ? [args[1]] : []
        }

        if allKeyCommands.contains(command) {
            return Array(args.dropFirst())
        }

        switch command {
        case "MSET", "MSETNX":
            return stride(from: 1, to: args.count, by: 2).map { args[$0] }
        case "RENAME", "RENAMENX", "COPY":
            return Array(args.dropFirst().prefix(2))
        case "MEMORY":
            if args.count > 2, args[1].uppercased() == "USAGE" {
                return [args[2]]
            }
            return []
        case "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO":
            guard args.count > 2, let keyCount = Int(args[2]) else { return [] }
            guard keyCount > 0 else { return [] }
            let start = 3
            let end = min(args.count, start + keyCount)
            return Array(args[start..<end])
        case "XREAD", "XREADGROUP":
            guard let streamsIndex = args.firstIndex(where: { $0.uppercased() == "STREAMS" }) else { return [] }
            let remaining = args[(streamsIndex + 1)...]
            return Array(remaining.prefix(remaining.count / 2))
        case "ZUNION", "ZINTER", "ZDIFF":
            guard args.count > 2, let keyCount = Int(args[1]) else { return [] }
            let start = 2
            let end = min(args.count, start + keyCount)
            return Array(args[start..<end])
        case "BITOP":
            // BITOP operation destkey srckey [srckey ...]
            return args.count > 2 ? [args[2]] : []
        case "BLMOVE":
            // BLMOVE src dst LEFT|RIGHT LEFT|RIGHT timeout
            return Array(args.dropFirst().prefix(2))
        case "ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE", "SUNIONSTORE", "SINTERSTORE", "SDIFFSTORE":
            guard args.count > 3, let keyCount = Int(args[2]) else {
                return args.count > 1 ? [args[1]] : []
            }
            let start = 3
            let end = min(args.count, start + keyCount)
            return [args[1]] + Array(args[start..<end])
        default:
            if blockingMultiKeyWithTimeoutCommands.contains(command), args.count > 2 {
                return Array(args.dropFirst().dropLast())
            }
            return args.count > 1 ? [args[1]] : []
        }
    }
}

enum RedisClusterRetryableError {
    /// Errors that mean "try again shortly" rather than a real failure.
    static func isRetryable(_ message: String) -> Bool {
        let upper = message.uppercased()
        return upper.hasPrefix("CLUSTERDOWN")
            || upper.hasPrefix("TRYAGAIN")
            || upper.hasPrefix("LOADING")
            || upper.hasPrefix("BUSY")
    }
}

enum RedisClusterHash {
    static let slotCount = 16_384

    static func slot(for key: String) -> Int {
        let bytes = Array(key.utf8)
        let hashBytes = hashTagBytes(in: bytes)
        return Int(crc16(hashBytes) % UInt16(slotCount))
    }

    private static func hashTagBytes(in bytes: [UInt8]) -> [UInt8] {
        guard let openIndex = bytes.firstIndex(of: UInt8(ascii: "{")) else {
            return bytes
        }

        let tagStart = openIndex + 1
        guard tagStart < bytes.count else {
            return bytes
        }

        guard let closeIndex = bytes[tagStart...].firstIndex(of: UInt8(ascii: "}")),
            closeIndex > tagStart
        else {
            return bytes
        }

        return Array(bytes[tagStart..<closeIndex])
    }

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc &<< 1) ^ 0x1021
                } else {
                    crc = crc &<< 1
                }
            }
        }
        return crc
    }
}
