import Foundation

// MARK: - Redis Function Models

/// A function library loaded into Redis (FUNCTION LIST).
struct RedisFunctionLibrary: Identifiable, Sendable {
    let name: String
    let engine: String  // currently always "LUA"
    let functions: [RedisFunction]
    let code: String  // library_code from FUNCTION LIST WITHCODE
    /// Primary nodes that contain this library. `nil` in standalone mode.
    var nodes: [RedisEndpoint]?

    var id: String { name }
    var functionCount: Int { functions.count }
    var isReadOnly: Bool { functions.allSatisfy { $0.isReadOnly } }
}

/// A single function registered inside a library.
struct RedisFunction: Identifiable, Sendable {
    let name: String
    let description: String?
    let flags: [String]  // "no-writes", "allow-oom", "allow-stale", "no-cluster"...

    var id: String { name }
    var isReadOnly: Bool { flags.contains("no-writes") }
}

/// The result of an FCALL / FCALL_RO invocation.
struct RedisFunctionCallResult: Identifiable, Sendable {
    let id = UUID()
    let functionName: String
    let keys: [String]
    let args: [String]
    let isReadOnly: Bool
    let response: RESPValue
    let error: String?
    let timestamp: Date
}

/// Restore policy for FUNCTION RESTORE.
enum RedisFunctionRestorePolicy: String, CaseIterable, Sendable {
    case flush = "FLUSH"
    case append = "APPEND"
    case replace = "REPLACE"

    var title: String { rawValue.capitalized }

    var description: String {
        switch self {
        case .flush: "Clear existing libraries, then import"
        case .append: "Add libraries, fail on name conflict"
        case .replace: "Add libraries, overwrite on name conflict"
        }
    }
}
