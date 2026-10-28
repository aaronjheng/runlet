import Foundation

// MARK: - Pub/Sub Subscription Mode

/// Whether the entered topics are literal channels (SUBSCRIBE) or glob
/// patterns (PSUBSCRIBE). RedisInsight defaults to pattern matching; a
/// pattern also matches plain channels, so it stays the default here.
enum PubSubSubscriptionMode: String, CaseIterable, Sendable {
    case channel
    case pattern

    var title: String {
        switch self {
        case .channel: return "Channel"
        case .pattern: return "Pattern"
        }
    }

    var commandName: String {
        switch self {
        case .channel: return "SUBSCRIBE"
        case .pattern: return "PSUBSCRIBE"
        }
    }

    var inputPlaceholder: String {
        switch self {
        case .channel: return "Channel names, space-separated (e.g. news sports)"
        case .pattern: return "Patterns, space-separated (e.g. news.* chat.*)"
        }
    }
}

// MARK: - Pub/Sub Subscription

/// One active subscription as requested by the user.
struct PubSubSubscription: Hashable, Sendable {
    let topic: String
    let mode: PubSubSubscriptionMode

    var commandText: String {
        "\(mode.commandName) \(topic)"
    }

    /// Splits the raw topic input into subscriptions, mirroring RedisInsight:
    /// whitespace-separated tokens, empty input collapses to the catch-all
    /// pattern `*`. Duplicates are dropped while order is preserved.
    static func parse(
        _ rawInput: String,
        mode: PubSubSubscriptionMode
    ) -> [PubSubSubscription] {
        var seen = Set<String>()
        var subscriptions: [PubSubSubscription] = []
        for token in rawInput.split(whereSeparator: \.isWhitespace) {
            let topic = String(token)
            guard seen.insert(topic).inserted else { continue }
            subscriptions.append(PubSubSubscription(topic: topic, mode: mode))
        }
        if subscriptions.isEmpty {
            subscriptions = [PubSubSubscription(topic: "*", mode: mode)]
        }
        return subscriptions
    }
}

// MARK: - Pub/Sub Message Entry

/// One received message shown in the PubSub list. Precomputes the display
/// strings at ingest (same discipline as `RedisProfilerEntry`) so filtering
/// and rendering never re-parse per row per body evaluation.
struct PubSubEntry: Identifiable, Hashable {
    /// Payloads beyond this length are truncated at ingest: the list retains
    /// thousands of entries and a single multi-megabyte message would otherwise
    /// dominate memory. The limit is measured in UTF-8 bytes so the in-memory
    /// bound stays close to 8 KB regardless of character width.
    static let maxPayloadLength = 8_192

    let id = UUID()
    let timestamp: Date
    let channel: String
    /// Matching pattern for pattern subscriptions; nil for exact channels.
    let pattern: String?
    let payload: String
    let receivedAt: Date
    /// Precomputed at ingest: HH:mm:ss.SSS of `receivedAt`.
    let timeText: String
    /// Precomputed at ingest: lowercase join used by the filter field.
    let searchText: String

    init(
        channel: String,
        pattern: String?,
        payload: String,
        receivedAt: Date = Date()
    ) {
        self.timestamp = receivedAt
        self.channel = channel
        self.pattern = pattern
        var storedPayload = payload
        if storedPayload.utf8.count > Self.maxPayloadLength {
            // Lossy decode mirrors `RESPParser.readPayload`: a truncated
            // boundary must not crash, invalid bytes become U+FFFD.
            let truncatedBytes = storedPayload.utf8.prefix(Self.maxPayloadLength)
            storedPayload = String(decoding: truncatedBytes, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
            storedPayload += "…"
        }
        self.payload = storedPayload
        self.receivedAt = receivedAt
        timeText = Self.formatTime(receivedAt)
        searchText = [channel, pattern ?? "", storedPayload].joined(separator: " ").lowercased()
    }

    /// Payload preview for the list row: single line, line breaks collapsed so
    /// multi-line payloads stay on one row.
    var payloadPreview: String {
        payload
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Channel cell text: pattern subscriptions surface the pattern that
    /// matched, so `pmessage` rows explain where they came from.
    var channelText: String {
        guard let pattern else { return channel }
        return "\(channel) · \(pattern)"
    }

    /// A ready-to-run `PUBLISH` command for context-menu actions. Built from
    /// the stored (possibly truncated) payload, so for over-long messages it
    /// republishes the preview rather than the original bytes.
    var publishCommand: String {
        "PUBLISH \(Self.quoted(channel)) \(Self.quoted(payload))"
    }

    private static func quoted(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "\"" }) else { return value }
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func formatTime(_ timestamp: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: timestamp)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let millisecond = (components.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", hour, minute, second, millisecond)
    }
}

// MARK: - Publish Draft

/// Publish-form values handed over by "Publish Again" actions elsewhere in the
/// PubSub panel. Consumed by `PubSubView`, which clears it after applying.
struct PubSubPublishDraft: Equatable, Sendable {
    let channel: String
    let message: String
}
