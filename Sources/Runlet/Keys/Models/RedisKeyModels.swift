import Foundation
import Observation

// MARK: - Redis Key Entry

@MainActor
@Observable
class RedisKeyEntry: Identifiable, Hashable {
    nonisolated let id = UUID()
    nonisolated let key: String
    var type: String
    var ttl: Int?
    var size: Int?
    var length: Int?

    init(key: String, type: String, ttl: Int?, size: Int?, length: Int? = nil) {
        self.key = key
        self.type = type
        self.ttl = ttl
        self.size = size
        self.length = length
    }

    var icon: String {
        switch type {
        case "string": return "doc.text"
        case "list": return "list.bullet"
        case "hash": return "tablecells"
        case "set": return "circle.grid.cross"
        case "zset": return "arrow.up.arrow.down.circle"
        default: return "questionmark.circle"
        }
    }

    var ttlText: String {
        guard let ttl else { return "No limit" }
        if ttl == -2 { return "Expired" }
        guard ttl > 0 else { return "No limit" }
        if ttl > 86400 { return "\(ttl / 86400)d" }
        if ttl > 3600 { return "\(ttl / 3600)h" }
        if ttl > 60 { return "\(ttl / 60)m" }
        return "\(ttl)s"
    }

    var hasExpiry: Bool {
        guard let ttl else { return false }
        return ttl > 0
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    nonisolated static func == (lhs: RedisKeyEntry, rhs: RedisKeyEntry) -> Bool {
        lhs.key == rhs.key
    }
}

/// Display title for a Redis key type, shared by badges, filters, and menus.
func redisKeyTypeTitle(_ type: String) -> String {
    switch type {
    case "string": "String"
    case "list": "List"
    case "hash": "Hash"
    case "set": "Set"
    case "zset": "ZSet"
    default: type
    }
}

enum KeyDetailOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }
}

enum StringValueFormat: String, CaseIterable, Identifiable, Codable {
    case raw
    case unicode
    case json
    case ascii
    case hex
    case base64
    case base64Encode
    case gzip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw: return "Raw"
        case .unicode: return "Unicode"
        case .json: return "JSON"
        case .ascii: return "ASCII"
        case .hex: return "Hex"
        case .base64: return "Base64"
        case .base64Encode: return "Base64 (Encode)"
        case .gzip: return "Gzip"
        }
    }
}

// MARK: - Key Namespace Tree

struct KeyNamespaceTree {
    let rootKeys: [RedisKeyEntry]
    let namespaces: [KeyNamespaceNode]
    let separator: String
    let allKeys: [RedisKeyEntry]

    init(entries: [RedisKeyEntry], separator: String) {
        self.separator = KeyNamespaceTree.normalizedSeparator(separator)
        self.allKeys = entries
        var root = KeyNamespaceNode.root
        for entry in entries {
            root.insert(entry, separator: self.separator)
        }
        root.sortRecursively()
        rootKeys = root.keys
        namespaces = root.children
    }

    static func namespaceSegments(for key: String, separator: String) -> [String] {
        let separatorCharacter = Character(normalizedSeparator(separator))
        let segments = key.split(separator: separatorCharacter, omittingEmptySubsequences: false).map(String.init)
        guard segments.count > 1 else { return [] }
        return segments.dropLast().filter { !$0.isEmpty }
    }

    static func leafName(for key: String, separator: String) -> String {
        let separatorCharacter = Character(normalizedSeparator(separator))
        guard let separatorIndex = key.lastIndex(of: separatorCharacter) else { return key }

        let suffixStart = key.index(after: separatorIndex)
        let suffix = String(key[suffixStart...])
        return suffix.isEmpty ? key : suffix
    }

    static func normalizedSeparator(_ value: String) -> String {
        String(value.first ?? ":")
    }
}

struct KeyNamespaceNode: Identifiable {
    let id: String
    let name: String
    var keys: [RedisKeyEntry] = []
    var children: [KeyNamespaceNode] = []

    static var root: KeyNamespaceNode {
        KeyNamespaceNode(id: "", name: "")
    }

    var keyCount: Int {
        keys.count + children.reduce(0) { $0 + $1.keyCount }
    }

    mutating func insert(_ entry: RedisKeyEntry, separator: String) {
        insert(
            entry,
            namespaceSegments: KeyNamespaceTree.namespaceSegments(for: entry.key, separator: separator),
            segmentIndex: 0,
            separator: separator
        )
    }

    mutating func sortRecursively() {
        keys.sort { lhs, rhs in
            lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }
        children.sort { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for index in children.indices {
            children[index].sortRecursively()
        }
    }

    private mutating func insert(
        _ entry: RedisKeyEntry,
        namespaceSegments: [String],
        segmentIndex: Int,
        separator: String
    ) {
        guard segmentIndex < namespaceSegments.count else {
            keys.append(entry)
            return
        }

        let namespaceName = namespaceSegments[segmentIndex]
        let namespaceID = id.isEmpty ? namespaceName : "\(id)\(separator)\(namespaceName)"
        if let childIndex = children.firstIndex(where: { $0.id == namespaceID }) {
            children[childIndex].insert(
                entry,
                namespaceSegments: namespaceSegments,
                segmentIndex: segmentIndex + 1,
                separator: separator
            )
        } else {
            var child = KeyNamespaceNode(id: namespaceID, name: namespaceName)
            child.insert(
                entry,
                namespaceSegments: namespaceSegments,
                segmentIndex: segmentIndex + 1,
                separator: separator
            )
            children.append(child)
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
