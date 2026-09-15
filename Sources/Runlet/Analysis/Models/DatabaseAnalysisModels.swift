import Foundation

// MARK: - Database Analysis Models

struct DatabaseAnalysis: Sendable {
    var totalKeys: Int = 0
    var totalMemory: Int = 0
    var typeDistribution: [String: TypeStats] = [:]
    var topKeysByMemory: [KeyMemoryEntry] = []
    var topNamespaces: [NamespaceStats] = []
    var expirationSummary: [ExpirationBucket] = []
    var serverMetrics = ServerMetrics()
    var analyzedAt = Date()
    var keysSampled = 0
    var isEstimate = false
}

struct TypeStats: Sendable {
    var count: Int = 0
    var memory: Int = 0
    var avgSize: Int { count != 0 ? memory / count : 0 }  // swiftlint:disable:this empty_count
}

struct KeyMemoryEntry: Identifiable, Sendable {
    let id = UUID()
    let key: String
    let type: String
    let memory: Int
    let length: Int
    let ttl: Int?

    var memoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .file)
    }
}

struct NamespaceStats: Identifiable, Sendable {
    let id = UUID()
    let namespace: String
    let keyCount: Int
    let totalMemory: Int
    let types: [String: Int]

    var memoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalMemory), countStyle: .file)
    }
}

struct ExpirationBucket: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let keyCount: Int
    let estimatedMemory: Int

    var memoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(estimatedMemory), countStyle: .file)
    }
}

struct ServerMetrics: Sendable {
    var usedMemory: Int = 0
    var usedMemoryHuman: String = ""
    var usedMemoryRSS: Int = 0
    var memoryFragmentationRatio: Double = 0
    var connectedClients: Int = 0
    var blockedClients: Int = 0
    var keyspaceHits: Int = 0
    var keyspaceMisses: Int = 0
    var hitRate: Double = 0
    var uptimeInSeconds: Int = 0
    var opsPerSecond: Int = 0
    var evictedKeys: Int = 0
    var expiredKeys: Int = 0
}
