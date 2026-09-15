import Foundation

// MARK: - Redis Command Catalog

/// Pure, framework-free catalog of Redis commands for shell auto-complete.
///
/// Extracted from `TabState` so completion logic is decoupled from session
/// state: it needs no connection, no view state, and no actor isolation,
/// which keeps it usable from anywhere (and trivially testable).
enum RedisCommandCatalog {
    private static let commands = [
        "APPEND", "AUTH", "BGREWRITEAOF", "BGSAVE", "BITCOUNT", "BITOP", "BITPOS",
        "BLPOP", "BRPOP", "BRPOPLPUSH", "CLIENT", "CLUSTER", "CONFIG", "DBSIZE",
        "DEBUG", "DECR", "DECRBY", "DEL", "DISCARD", "DUMP", "ECHO", "EVAL", "EVALSHA",
        "EXEC", "EXISTS", "EXPIRE", "EXPIREAT", "FCALL", "FCALL_RO",
        "FLUSHALL", "FLUSHDB", "FUNCTION", "GEOADD",
        "GEODIST", "GEOHASH", "GEOPOS", "GET", "GETBIT", "GETRANGE", "GETSET",
        "HDEL", "HEXISTS", "HGET", "HGETALL", "HINCRBY", "HINCRBYFLOAT", "HKEYS",
        "HLEN", "HMGET", "HMSET", "HSCAN", "HSET", "HSETNX", "HVALS", "INCR",
        "INCRBY", "INCRBYFLOAT", "INFO", "KEYS", "LASTSAVE", "LINDEX", "LINSERT",
        "LLEN", "LPOP", "LPUSH", "LPUSHX", "LRANGE", "LREM", "LSET", "LTRIM",
        "MEMORY", "MGET", "MIGRATE", "MONITOR", "MOVE", "MSET", "MSETNX", "MULTI",
        "OBJECT", "PERSIST", "PEXPIRE", "PEXPIREAT", "PFADD", "PFCOUNT", "PFMERGE",
        "PING", "PSETEX", "PSUBSCRIBE", "PTTL", "PUBLISH", "PUBSUB", "PUNSUBSCRIBE",
        "QUIT", "RANDOMKEY", "READONLY", "READWRITE", "RENAME", "RENAMENX", "RESTORE",
        "ROLE", "RPOP", "RPOPLPUSH", "RPUSH", "RPUSHX", "SADD", "SAVE", "SCAN",
        "SCARD", "SCRIPT", "SDIFF", "SDIFFSTORE", "SELECT", "SET", "SETBIT",
        "SETEX", "SETNX", "SETRANGE", "SHUTDOWN", "SINTER", "SINTERSTORE", "SISMEMBER",
        "SLAVEOF", "SLOWLOG", "SMEMBERS", "SMOVE", "SORT", "SPOP", "SRANDMEMBER",
        "SREM", "SSCAN", "STRLEN", "SUBSCRIBE", "SUNION", "SUNIONSTORE", "SYNC",
        "TIME", "TOUCH", "TTL", "TYPE", "UNLINK", "UNSUBSCRIBE", "UNWATCH", "WAIT",
        "WATCH", "ZADD", "ZCARD",
        "ZCOUNT", "ZINCRBY", "ZINTERSTORE", "ZLEXCOUNT", "ZPOPMAX", "ZPOPMIN",
        "ZRANGE", "ZRANGEBYLEX", "ZRANGEBYSCORE", "ZRANK", "ZREM", "ZREMRANGEBYLEX",
        "ZREMRANGEBYRANK", "ZREMRANGEBYSCORE", "ZREVRANGE", "ZREVRANGEBYLEX",
        "ZREVRANGEBYSCORE", "ZREVRANK", "ZSCAN", "ZSCORE", "ZUNIONSTORE",
    ]

    static func completions(for prefix: String) -> [String] {
        let upper = prefix.uppercased()
        return commands.filter { $0.hasPrefix(upper) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
