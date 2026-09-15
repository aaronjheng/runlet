import Foundation
import Synchronization

// MARK: - Profiler

final class RedisProfilerTaskBag: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    func add(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    func cancelAll() {
        let tasks = self.tasks.withLock { state -> [Task<Void, Never>] in
            let tasks = state
            state.removeAll()
            return tasks
        }

        for task in tasks {
            task.cancel()
        }
    }
}

struct RedisProfilerCapture: Sendable {
    let node: RedisEndpoint?
    let line: String
}

struct RedisProfilerStream {
    let stream: AsyncThrowingStream<RedisProfilerCapture, Error>
    let monitorClients: [RedisMonitorClient]
    let monitorTasks: RedisProfilerTaskBag?
    let tunnel: SSHTunnel?
    let tunnelManager: SSHClusterTunnelManager?
}

struct RedisProfilerEntry: Identifiable, Hashable {
    private struct ParsedLine {
        let timestamp: Date
        let database: Int?
        let source: String
        let commandName: String
        let arguments: [String]
        /// Literal text preceding the command arguments (timestamp + metadata),
        /// used to rebuild a redacted raw line.
        let prefix: String
        /// The raw command portion string, used when arguments is empty.
        let commandRemainder: String
    }

    let id = UUID()
    let timestamp: Date
    let database: Int?
    let source: String
    let commandName: String
    let commandText: String
    let arguments: [String]
    let rawLine: String
    let node: RedisEndpoint?

    init(rawLine: String, node: RedisEndpoint? = nil, capturedAt: Date = Date()) {
        self.node = node

        let parsed = Self.parse(rawLine: rawLine, capturedAt: capturedAt)
        timestamp = parsed.timestamp
        database = parsed.database
        source = parsed.source
        commandName = parsed.commandName

        // Redact sensitive arguments before they reach the UI or memory.
        let redactedArguments = Self.redactArguments(parsed.arguments)
        arguments = redactedArguments
        commandText =
            redactedArguments.isEmpty
            ? parsed.commandRemainder
            : redactedArguments.map(Self.displayArgument).joined(separator: " ")

        if redactedArguments == parsed.arguments {
            self.rawLine = rawLine
        } else {
            self.rawLine = parsed.prefix + commandText
        }
    }

    var databaseText: String {
        database.map(String.init) ?? "-"
    }

    var nodeText: String {
        node?.address ?? "-"
    }

    var timeText: String {
        let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: timestamp)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let millisecond = (components.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", hour, minute, second, millisecond)
    }

    var argumentsText: String {
        guard arguments.count > 1 else { return "" }
        return arguments.dropFirst().map(Self.displayArgument).joined(separator: " ")
    }

    /// The invoked function name for `FCALL` / `FCALL_RO` entries, otherwise `nil`.
    ///
    /// Redis MONITOR quotes every argument, so `arguments[0]` is the command
    /// and `arguments[1]` is the function name (`FCALL <function> <numkeys> ...`).
    var fcallFunctionName: String? {
        guard commandName == "FCALL" || commandName == "FCALL_RO" else { return nil }
        guard arguments.count >= 2 else { return nil }
        let name = arguments[1]
        return name.isEmpty ? nil : name
    }

    /// Resolves the owning library for an `FCALL` / `FCALL_RO` entry by looking
    /// up the invoked function name across the loaded function libraries.
    ///
    /// Function names are globally unique in Redis, so the first match wins.
    /// Returns the qualified `library.function` form, or `nil` when the entry is
    /// not a function call or no matching library is loaded. The libraries are
    /// passed in to keep this model free of a `TabState` dependency.
    func fcallLibraryName(in libraries: [RedisFunctionLibrary]) -> String? {
        guard let functionName = fcallFunctionName,
            let library = libraries.first(where: { $0.functions.contains { $0.name == functionName } })
        else { return nil }
        return "\(library.name).\(functionName)"
    }

    var searchText: String {
        ([databaseText, nodeText, source, commandName, commandText, rawLine] + arguments)
            .joined(separator: " ")
            .lowercased()
    }

    var isNoiseCommand: Bool {
        switch commandName {
        case "PING":
            return true
        case "CLUSTER":
            guard arguments.count > 1 else { return false }
            return Self.noiseClusterSubcommands.contains(arguments[1].uppercased())
        default:
            return false
        }
    }

    private static let noiseClusterSubcommands: Set<String> = [
        "INFO",
        "NODES",
        "SHARDS",
        "SLOTS",
    ]

    private static func parse(
        rawLine: String,
        capturedAt: Date
    ) -> ParsedLine {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestampEnd = trimmed.firstIndex(of: " ") ?? trimmed.endIndex
        let timestampText = String(trimmed[..<timestampEnd])
        let timestamp = Double(timestampText).map { Date(timeIntervalSince1970: $0) } ?? capturedAt

        var remainder =
            timestampEnd < trimmed.endIndex
            ? String(trimmed[trimmed.index(after: timestampEnd)...]).trimmingCharacters(in: .whitespaces)
            : ""

        var database: Int?
        var source = "-"
        var prefix = ""

        if remainder.first == "[", let closeBracketIndex = remainder.firstIndex(of: "]") {
            let metadataStart = remainder.index(after: remainder.startIndex)
            let metadata = String(remainder[metadataStart..<closeBracketIndex])
            let parts = metadata.split(separator: " ", maxSplits: 1).map(String.init)
            database = parts.first.flatMap(Int.init)
            if parts.count > 1 {
                source = parts[1]
            } else if !metadata.isEmpty {
                source = metadata
            }
            prefix = "\(timestampText) [\(metadata)] "

            let commandStart = remainder.index(after: closeBracketIndex)
            remainder = String(remainder[commandStart...]).trimmingCharacters(in: .whitespaces)
        } else if timestampEnd < trimmed.endIndex {
            prefix = "\(timestampText) "
        }

        let arguments = parseArguments(remainder)
        let commandName = arguments.first?.uppercased() ?? "-"
        return ParsedLine(
            timestamp: timestamp,
            database: database,
            source: source,
            commandName: commandName,
            arguments: arguments,
            prefix: prefix,
            commandRemainder: remainder
        )
    }

    private static func parseArguments(_ value: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false

        for character in value {
            if isQuoted {
                if isEscaped {
                    current.append(unescaped(character))
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    arguments.append(current)
                    current = ""
                    isQuoted = false
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                isQuoted = true
            }
        }

        if isQuoted || !current.isEmpty {
            arguments.append(current)
        }

        return arguments
    }

    private static func unescaped(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        default: return character
        }
    }

    private static func displayArgument(_ value: String) -> String {
        if value.isEmpty {
            return "\"\""
        }

        let needsQuoting = value.contains { character in
            character.isWhitespace || character == "\""
        }
        guard needsQuoting else { return value }

        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    // MARK: - Sensitive Argument Redaction

    /// Redacts sensitive arguments (passwords, secrets) from a parsed command.
    /// `arguments[0]` is the command verb. Mirrors the redaction applied to shell
    /// history so captured commands never expose secrets in the UI or memory.
    private static func redactArguments(_ arguments: [String]) -> [String] {
        guard let verb = arguments.first else { return arguments }
        switch verb.uppercased() {
        case "AUTH":
            guard arguments.count > 1 else { return arguments }
            return [verb] + Array(repeating: "****", count: arguments.count - 1)
        case "CONFIG":
            return redactConfigArguments(arguments)
        case "ACL":
            return redactAclArguments(arguments)
        case "MIGRATE":
            return redactMigrateArguments(arguments)
        case "HELLO":
            return redactHelloArguments(arguments)
        default:
            return arguments
        }
    }

    private static func redactConfigArguments(_ arguments: [String]) -> [String] {
        // CONFIG SET <key> <value> — redact value for password-related keys
        guard arguments.count >= 4, arguments[1].uppercased() == "SET" else { return arguments }
        let sensitiveKeys: Set<String> = ["requirepass", "masterauth", "masteruser"]
        guard sensitiveKeys.contains(arguments[2].lowercased()) else { return arguments }
        var redacted = arguments
        for index in 3..<redacted.count {
            redacted[index] = "****"
        }
        return redacted
    }

    private static func redactAclArguments(_ arguments: [String]) -> [String] {
        // ACL SETUSER <user> … — redact password rules (>… / <…)
        guard arguments.count >= 3, arguments[1].uppercased() == "SETUSER" else { return arguments }
        return arguments.map { token in
            if token.hasPrefix(">") { return ">****" }
            if token.hasPrefix("<") { return "<****" }
            return token
        }
    }

    private static func redactMigrateArguments(_ arguments: [String]) -> [String] {
        // MIGRATE … AUTH <password> | AUTH2 <username> <password>
        var redacted: [String] = []
        var index = 0
        while index < arguments.count {
            let upper = arguments[index].uppercased()
            if upper == "AUTH" && index + 1 < arguments.count {
                redacted.append(arguments[index])
                redacted.append("****")
                index += 2
            } else if upper == "AUTH2" && index + 2 < arguments.count {
                redacted.append(arguments[index])
                redacted.append("****")
                redacted.append("****")
                index += 3
            } else {
                redacted.append(arguments[index])
                index += 1
            }
        }
        return redacted
    }

    private static func redactHelloArguments(_ arguments: [String]) -> [String] {
        // HELLO [protover] [AUTH username password] [SETNAME name]
        guard let authIndex = arguments.firstIndex(where: { $0.uppercased() == "AUTH" }),
            authIndex + 2 < arguments.count
        else { return arguments }
        var redacted = arguments
        redacted[authIndex + 1] = "****"
        redacted[authIndex + 2] = "****"
        return redacted
    }
}
