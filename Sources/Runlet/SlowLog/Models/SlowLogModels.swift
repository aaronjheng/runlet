import Foundation

// MARK: - Slow Log Models

struct SlowLogEntry: Identifiable, Sendable {
    let id: Int
    let timestamp: Date
    let duration: Int  // microseconds
    let command: [String]
    let clientIP: String
    let clientName: String

    var durationMs: Double {
        Double(duration) / 1000.0
    }

    var durationText: String {
        if duration >= 1_000_000 {
            return String(format: "%.2f s", Double(duration) / 1_000_000)
        } else if duration >= 1_000 {
            return String(format: "%.2f ms", Double(duration) / 1_000)
        } else {
            return "\(duration) \u{00B5}s"
        }
    }

    /// ISO 8601 timestamp in local time, e.g. `2026-09-09T14:23:05+08:00`.
    var timestampText: String {
        Self.iso8601Formatter.string(from: timestamp)
    }

    /// Relative age for tooltips, e.g. `3 minutes ago`.
    var relativeTimestampText: String {
        Self.relativeFormatter.localizedString(for: timestamp, relativeTo: .now)
    }

    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    private nonisolated(unsafe) static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    var commandText: String {
        command.joined(separator: " ")
    }
}

/// In-memory viewing parameters for the slow-log panel. Nothing here is
/// persisted: `threshold` only feeds the empty-state hint and
/// `autoRefreshInterval` is transient "am I watching" state.
struct SlowLogConfig: Equatable {
    var threshold: Int = 10_000  // microseconds
    /// Transient UI state ("am I watching right now"): every launch starts
    /// with polling off.
    var autoRefreshInterval: TimeInterval = 0  // 0 = disabled

    static let autoRefreshOptions: [(title: String, value: TimeInterval)] =
        [
            ("Off", 0)
        ] + AutoRefreshInterval.options.map { (AutoRefreshInterval.title($0), $0) }
}
