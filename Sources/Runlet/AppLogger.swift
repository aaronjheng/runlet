import Foundation
import os

/// AppLogger wraps macOS Unified Logging (os.Logger) for structured logging.
///
/// Logs are viewable in Console.app or via:
/// ```sh
/// log stream --predicate 'subsystem == "app.runlet"'
/// ```
enum AppLogger {
    private static let subsystem = "app.runlet"

    private static func logger(for category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Log info level message
    static func info(_ message: String, category: String = "App", fields: [String: String] = [:]) {
        logger(for: category).info("\(format(message, fields), privacy: .public)")
    }

    /// Log error level message
    static func error(_ message: String, category: String = "App", fields: [String: String] = [:]) {
        logger(for: category).error("\(format(message, fields), privacy: .public)")
    }

    /// Log warning level message
    static func warn(_ message: String, category: String = "App", fields: [String: String] = [:]) {
        logger(for: category).warning("\(format(message, fields), privacy: .public)")
    }

    /// Log debug level message (only in DEBUG builds)
    static func debug(_ message: String, category: String = "App", fields: [String: String] = [:]) {
        #if DEBUG
            logger(for: category).debug("\(format(message, fields), privacy: .public)")
        #endif
    }

    private static func format(_ message: String, _ fields: [String: String]) -> String {
        guard !fields.isEmpty else { return message }
        let extras =
            fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "\(message) \(extras)"
    }
}
