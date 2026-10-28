import Foundation

/// Resources built for one subscription attempt: the message stream plus the
/// client/tunnel objects that must be torn down when it ends. A struct rather
/// than a tuple keeps ownership explicit and the linter happy.
private struct PubSubStreamResources {
    let stream: AsyncThrowingStream<RedisPubSubPush, Error>
    let client: RedisClient
    let tunnel: SSHTunnel?
    let tunnelManager: SSHClusterTunnelManager?
}

extension TabState {
    // MARK: - Pub/Sub

    /// Starts streaming messages for the given subscriptions on a dedicated
    /// client. Follows the profiler lifecycle: one generation token, resources
    /// built locally and published only after the generation is confirmed, so
    /// a superseded start can never clobber the active generation's state.
    func startPubSub(
        subscriptions rawSubscriptions: [PubSubSubscription]
    ) {
        guard !isPubSubSubscribed && !isPubSubSubscribing else { return }
        guard let config = connectedConfig ?? selectedConnection else {
            pubSubError = "Connect to a Redis server before subscribing."
            return
        }
        guard !rawSubscriptions.isEmpty else { return }

        let subscriptions = rawSubscriptions
        let isPattern = subscriptions.allSatisfy { $0.mode == .pattern }
        // Mixed input is normalized: everything becomes PSUBSCRIBE, which
        // matches literal channels too.
        let topics = subscriptions.map { $0.topic }

        AppLogger.info(
            "pubsub starting",
            category: "PubSub",
            fields: [
                "redis": config.address,
                "mode": isPattern ? "psubscribe" : "subscribe",
                "topics": topics.joined(separator: ","),
            ]
        )

        pubSubGeneration += 1
        let generation = pubSubGeneration
        cancelPubSubResources()
        pubSubError = nil
        isPubSubSubscribing = true

        pubSubTask = Task { @MainActor in
            await runPubSub(
                config: config,
                topics: topics,
                isPattern: isPattern,
                subscriptions: subscriptions,
                generation: generation
            )
        }
    }

    func stopPubSub(clearEntries: Bool = false) {
        pubSubGeneration += 1
        cancelPubSubResources()
        isPubSubSubscribed = false
        isPubSubSubscribing = false
        pubSubSubscriptions = []

        if clearEntries {
            clearPubSubMessages()
        }
    }

    /// Clears the message list while keeping the subscription alive
    /// (RedisInsight's clear button behaves the same way).
    func clearPubSubMessages() {
        pubSubFlushTask?.cancel()
        pubSubFlushTask = nil
        pubSubPendingEntries = []
        pubSubEntries = []
        pubSubReceivedCount = 0
    }

    /// Fills the publish form without executing. Consumed by `PubSubView` via
    /// `pubSubPendingPublish`.
    func openInPubSubPublishForm(channel: String, message: String) {
        pubSubPendingPublish = PubSubPublishDraft(channel: channel, message: message)
    }

    /// Publishes via the live session (PUBLISH is broadcast cluster-wide on
    /// Redis 7+, so the default-routed node delivers to every subscriber).
    /// Returns the number of clients the message was delivered to.
    @discardableResult
    func publishPubSubMessage(channel: String, message: String) async -> Int? {
        let trimmedChannel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChannel.isEmpty else { return nil }
        guard let session = activeSession, session.isConnected else {
            pubSubError = "Connect to a Redis server before publishing."
            return nil
        }
        do {
            let result = try await session.send(["PUBLISH", trimmedChannel, message])
            try throwIfRedisError(result)
            pubSubError = nil
            return result.intValue
        } catch {
            pubSubError = error.localizedDescription
            AppLogger.error("pubsub publish failed error=\(error)", category: "PubSub")
            return nil
        }
    }

    // MARK: - Lifecycle Internals

    private func cancelPubSubResources() {
        pubSubTask?.cancel()
        pubSubTask = nil

        pubSubFlushTask?.cancel()
        pubSubFlushTask = nil
        flushPubSubEntries()

        pubSubClient?.disconnect()
        pubSubClient = nil

        pubSubSSHTunnel?.stop()
        pubSubSSHTunnel = nil

        let clusterTunnelManager = pubSubClusterTunnelManager
        pubSubClusterTunnelManager = nil
        Task {
            await clusterTunnelManager?.disconnect()
        }
    }

    private func runPubSub(
        config: RedisConnectionConfig,
        topics: [String],
        isPattern: Bool,
        subscriptions: [PubSubSubscription],
        generation: Int
    ) async {
        // Holds the locally built resources until they are either published to
        // shared state (current generation) or disposed (superseded).
        var pendingClient: RedisClient?
        var pendingTunnel: SSHTunnel?
        var pendingTunnelManager: SSHClusterTunnelManager?

        defer {
            flushPubSubEntries()
            if pubSubGeneration == generation {
                pubSubTask = nil
                isPubSubSubscribed = false
                isPubSubSubscribing = false
                pubSubSubscriptions = []
                pubSubClient?.disconnect()
                pubSubClient = nil
                pubSubSSHTunnel?.stop()
                pubSubSSHTunnel = nil
                // Deterministic teardown, mirroring `runProfiler`'s defer.
                let tunnelManager = pubSubClusterTunnelManager
                pubSubClusterTunnelManager = nil
                await tunnelManager?.disconnect()
            }
            pendingClient?.disconnect()
            pendingTunnel?.stop()
            await pendingTunnelManager?.disconnect()
        }

        do {
            let resources = try await startPubSubStream(
                config: config,
                topics: topics,
                isPattern: isPattern
            )
            pendingClient = resources.client
            pendingTunnel = resources.tunnel
            pendingTunnelManager = resources.tunnelManager

            // A superseded generation (stopPubSub already advanced the
            // generation and cancelled this task) must not publish its
            // resources, otherwise it would overwrite the active generation's
            // references. Tear the local copies down instead (the defer above).
            try Task.checkCancellation()
            guard pubSubGeneration == generation else { return }

            pubSubClient = pendingClient
            pubSubSSHTunnel = pendingTunnel
            pubSubClusterTunnelManager = pendingTunnelManager
            pendingClient = nil
            pendingTunnel = nil
            pendingTunnelManager = nil

            isPubSubSubscribing = false
            isPubSubSubscribed = true
            pubSubSubscriptions = subscriptions
            AppLogger.info(
                "pubsub started redis=\(config.address)",
                category: "PubSub"
            )

            for try await push in resources.stream {
                try Task.checkCancellation()
                appendPubSubPush(push)
            }

            // The stream ended without an error: the server closed the
            // subscription connection.
            if pubSubGeneration == generation {
                pubSubError = "Subscription connection closed by the server."
                isPubSubSubscribed = false
                isPubSubSubscribing = false
                pubSubSubscriptions = []
            }
            AppLogger.info("pubsub stream ended redis=\(config.address)", category: "PubSub")
        } catch is CancellationError {
            AppLogger.info("pubsub cancelled redis=\(config.address)", category: "PubSub")
        } catch {
            if pubSubGeneration == generation {
                pubSubError = error.localizedDescription
                isPubSubSubscribed = false
                isPubSubSubscribing = false
                pubSubSubscriptions = []
            }
            AppLogger.error(
                "pubsub failed redis=\(config.address) error=\(error)", category: "PubSub")
        }
    }

    /// Builds the dedicated subscription connection (own SSH tunnel when the
    /// session uses one) and returns its message stream plus the resources that
    /// back it. Resources are returned only after full success — any failure
    /// path disconnects everything that was built before throwing.
    private func startPubSubStream(
        config: RedisConnectionConfig,
        topics: [String],
        isPattern: Bool
    ) async throws -> PubSubStreamResources {
        var connectHost = config.host
        var connectPort = config.port
        var tunnel: SSHTunnel?
        var tunnelManager: SSHClusterTunnelManager?
        var client: RedisClient?

        do {
            if config.ssh.enabled {
                switch config.mode {
                case .standalone:
                    let createdTunnel = try await SSHTunnel.connect(
                        config: config.ssh,
                        remoteHost: config.host,
                        remotePort: config.port
                    )
                    tunnel = createdTunnel
                    connectHost = "127.0.0.1"
                    connectPort = createdTunnel.localPort
                case .cluster:
                    // Cluster pub/sub is broadcast (Redis 7+), so one node is
                    // enough; the seed node keeps the setup simple. Sharded
                    // channels (SSUBSCRIBE) only exist on their owning shard.
                    let manager = SSHClusterTunnelManager(ssh: config.ssh)
                    tunnelManager = manager
                    let endpoint = try await manager.clientEndpoint(
                        for: RedisEndpoint(host: config.host, port: config.port)
                    )
                    connectHost = endpoint.host
                    connectPort = endpoint.port
                }
            }

            try Task.checkCancellation()

            let builtClient = makePubSubClient(config: config, host: connectHost, port: connectPort)
            client = builtClient
            let stream = try await withTimeout(config.connectionTimeout, context: "Pub/Sub subscription") {
                try await builtClient.startPubSub(subscriptions: topics, isPattern: isPattern)
            }
            return PubSubStreamResources(
                stream: stream,
                client: builtClient,
                tunnel: tunnel,
                tunnelManager: tunnelManager
            )
        } catch {
            client?.disconnect()
            tunnel?.stop()
            await tunnelManager?.disconnect()
            throw error
        }
    }

    private func makePubSubClient(
        config: RedisConnectionConfig,
        host: String,
        port: UInt16
    ) -> RedisClient {
        // Dedicated RESP2 connection with the plain AUTH handshake (no HELLO):
        // in RESP2 subscription confirmations are ordinary replies, so they
        // match the in-flight SUBSCRIBE/PSUBSCRIBE commands. Never send other
        // commands on it once subscriptions are in place.
        RedisClient(
            host: host,
            port: port,
            username: config.username.isEmpty ? nil : config.username,
            password: config.password.isEmpty ? nil : config.password,
            tlsEnabled: config.tls.enabled,
            verifyServerCertificate: config.tls.verifyServerCertificate,
            caCertificatePath: config.tls.caCertificatePath,
            clientCertificatePath: config.tls.clientCertificatePath,
            clientKeyPath: config.tls.clientKeyPath,
            preferredProtocolVersion: .resp2,
            connectionTimeout: config.connectionTimeout
        )
    }

    // MARK: - Message Ingest

    private func appendPubSubPush(_ push: RedisPubSubPush) {
        guard push.kind.isDelivery, let payload = push.payload else { return }
        pubSubPendingEntries.append(
            PubSubEntry(
                channel: push.channel,
                pattern: push.pattern,
                payload: payload
            )
        )
        schedulePubSubFlush()
    }

    /// Schedules a single delayed flush; messages arriving before it fires join
    /// the same batch, so one `@Observable` write covers the whole window.
    private func schedulePubSubFlush() {
        guard pubSubFlushTask == nil else { return }
        let generation = pubSubGeneration
        pubSubFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            // A stop/restart advanced the generation and already flushed (or
            // discarded) these messages synchronously; never touch newer state.
            guard generation == self.pubSubGeneration else { return }
            self.flushPubSubEntries()
        }
    }

    private func flushPubSubEntries() {
        pubSubFlushTask = nil
        guard !pubSubPendingEntries.isEmpty else { return }
        let pending = pubSubPendingEntries
        pubSubPendingEntries = []
        pubSubReceivedCount += pending.count
        pubSubEntries.append(contentsOf: pending)

        if pubSubEntries.count > pubSubMaxEntries {
            // Slice off the excess in one pass; removeFirst(1) per entry was O(n²).
            pubSubEntries.removeFirst(pubSubEntries.count - pubSubMaxEntries)
        }
    }
}
