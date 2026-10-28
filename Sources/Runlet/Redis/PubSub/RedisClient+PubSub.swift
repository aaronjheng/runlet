import Foundation

// MARK: - Pub/Sub Push Message

/// One decoded pub/sub message from a dedicated subscription connection.
///
/// The dedicated client runs RESP2, where the server delivers every
/// subscription event as a plain array: confirmations
/// (`["subscribe", channel, count]`) arrive as replies to the in-flight
/// `SUBSCRIBE`/`PSUBSCRIBE` command, while later messages
/// (`["message", channel, payload]`, `["pmessage", pattern, channel, payload]`)
/// match no in-flight request and are routed to the pub/sub stream.
struct RedisPubSubPush: Sendable {
    enum Kind: String, Sendable {
        case subscribe
        case psubscribe
        case unsubscribe
        case punsubscribe
        case message
        case pmessage

        var isDelivery: Bool {
            self == .message || self == .pmessage
        }
    }

    let kind: Kind
    /// Delivery channel (or the confirmed pattern for `psubscribe` events).
    let channel: String
    /// Matching pattern for `pmessage` / pattern confirmations; otherwise nil.
    let pattern: String?
    /// Published payload for message deliveries; otherwise nil.
    let payload: String?
    /// Number of remaining subscriptions on confirmation events.
    let subscriptionCount: Int?

    init?(response: RESPValue) {
        guard case .array(let items) = response, !items.isEmpty,
            let kindName = items[0]?.string,
            let kind = Kind(rawValue: kindName.lowercased())
        else { return nil }

        switch kind {
        case .subscribe, .unsubscribe:
            guard items.count >= 3 else { return nil }
            self.kind = kind
            channel = items[1]?.string ?? ""
            pattern = nil
            payload = nil
            subscriptionCount = items[2]?.intValue

        case .psubscribe, .punsubscribe:
            guard items.count >= 3 else { return nil }
            self.kind = kind
            channel = items[1]?.string ?? ""
            pattern = items[1]?.string
            payload = nil
            subscriptionCount = items[2]?.intValue

        case .message:
            guard items.count >= 3 else { return nil }
            self.kind = kind
            channel = items[1]?.string ?? ""
            pattern = nil
            payload = items[2]?.string
            subscriptionCount = nil

        case .pmessage:
            guard items.count >= 4 else { return nil }
            self.kind = kind
            channel = items[2]?.string ?? ""
            pattern = items[1]?.string
            payload = items[3]?.string
            subscriptionCount = nil
        }
    }
}

// MARK: - Pub/Sub Subscription

/// Pub/Sub streaming for `RedisClient`, mirroring `startMonitoring()`.
///
/// A connection that enters subscribe mode becomes a dedicated push stream:
/// after the subscription confirmations, every subsequent message is
/// unsolicited pub/sub output that matches no in-flight request.
/// `processBuffer()` routes those arrays here instead of dropping them.
///
/// The client must be created with `preferredProtocolVersion == .resp2`:
/// in RESP3 the subscription confirmations arrive as PUSH frames (which this
/// client drops), so the awaited reply would never match and the handshake
/// would hang. Callers must never send other commands on the connection once
/// subscriptions are in place.
extension RedisClient {
    /// Subscribes to each pattern (PSUBSCRIBE) or channel (SUBSCRIBE) and
    /// returns the stream of subsequent messages. Confirmations are awaited
    /// inline so the caller knows every subscription is active on return.
    func startPubSub(
        subscriptions: [String],
        isPattern: Bool
    ) async throws -> AsyncThrowingStream<RedisPubSubPush, Error> {
        let (stream, continuation) = AsyncThrowingStream<RedisPubSubPush, Error>.makeStream(
            of: RedisPubSubPush.self,
            throwing: Error.self,
            bufferingPolicy: .bufferingNewest(2_000)
        )

        state.withLock { $0.pubSubContinuation = continuation }

        continuation.onTermination = { [weak self] _ in
            self?.disconnect()
        }

        do {
            if !isConnected {
                try await connect()
            }
            state.withLock { $0.isPubSub = true }

            let command = isPattern ? "PSUBSCRIBE" : "SUBSCRIBE"
            for subscription in subscriptions {
                let result = try await send([command, subscription])
                try throwIfRedisError(result)
                guard let confirmation = RedisPubSubPush(response: result),
                    confirmation.kind == (isPattern ? .psubscribe : .subscribe),
                    confirmation.channel == subscription
                else {
                    throw RedisError.commandError(
                        "Unexpected \(command) response: \(result.displayString)")
                }
            }

            return stream
        } catch {
            disconnect()
            throw error
        }
    }

    func finishPubSub(with error: Error?) {
        let continuation = state.withLock {
            let continuation = $0.pubSubContinuation
            $0.pubSubContinuation = nil
            $0.isPubSub = false
            return continuation
        }

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}
