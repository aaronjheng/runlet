import Foundation

// MARK: - Slow Log Models

struct SlowLogEntry: Identifiable, Sendable {
    let id: Int
    let timestamp: Date
    let duration: Int  // microseconds
    let command: [String]
    let clientIP: String
    let clientName: String
    /// Precomputed at fetch: the filter lowercases three fields per row per
    /// keystroke, and the columns reformat per body.
    let searchText: String
    let durationText: String
    let timestampText: String

    init(id: Int, timestamp: Date, duration: Int, command: [String], clientIP: String, clientName: String) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.command = command
        self.clientIP = clientIP
        self.clientName = clientName
        self.durationText = Self.formatDuration(duration)
        self.timestampText = Self.iso8601Formatter.string(from: timestamp)
        self.searchText = ([command.joined(separator: " "), clientIP, clientName]).joined(separator: " ").lowercased()
    }

    var durationMs: Double {
        Double(duration) / 1000.0
    }

    private static func formatDuration(_ duration: Int) -> String {
        if duration >= 1_000_000 {
            return (Double(duration) / 1_000_000).formatted(.number.precision(.fractionLength(2))) + " s"
        } else if duration >= 1_000 {
            return (Double(duration) / 1_000).formatted(.number.precision(.fractionLength(2))) + " ms"
        } else {
            return "\(duration) µs"
        }
    }

    /// Relative age for tooltips stays computed: it depends on `.now`.
    /// E.g. `3 minutes ago`.
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
