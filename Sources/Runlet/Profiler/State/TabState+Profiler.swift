import Foundation

extension TabState {
    // MARK: - Profiler

    func startProfiler() {
        guard !isProfilerRunning && !isProfilerStarting else { return }
        // `selectedConnection` can hold edits saved after connecting (which
        // do not reconnect), so MONITOR must authenticate with the config the
        // live session was established with — otherwise a password added via
        // Save would fail against servers that need none, while Keys (which
        // rides the live session) keeps working.
        guard let config = connectedConfig ?? selectedConnection else {
            profilerError = "Connect to a Redis server before starting the profiler."
            return
        }
        AppLogger.info(
            "profiler starting",
            category: "Profiler",
            fields: [
                "redis": config.address,
                "auth_configured": "\(!config.password.isEmpty)",
                "live_session": "\(connectedConfig != nil)",
            ]
        )

        profilerGeneration += 1
        let generation = profilerGeneration
        cancelProfilerResources()
        profilerError = nil
        isProfilerStarting = true

        profilerTask = Task { @MainActor in
            await runProfiler(config: config, generation: generation)
        }
    }

    func stopProfiler(clearEntries: Bool = false) {
        profilerGeneration += 1
        cancelProfilerResources()
        isProfilerRunning = false
        isProfilerStarting = false

        if clearEntries {
            clearProfiler()
        }
    }

    func clearProfiler() {
        profilerFlushTask?.cancel()
        profilerFlushTask = nil
        profilerPendingCaptures = []
        profilerEntries = []
        profilerCapturedCount = 0
        profilerError = nil
    }

    private func cancelProfilerResources() {
        profilerTask?.cancel()
        profilerTask = nil

        profilerFlushTask?.cancel()
        profilerFlushTask = nil
        flushProfilerCaptures()

        profilerMonitorTasks?.cancelAll()
        profilerMonitorTasks = nil

        for client in profilerMonitorClients {
            client.disconnect()
        }
        profilerMonitorClients = []

        profilerSSHTunnel?.stop()
        profilerSSHTunnel = nil

        let clusterTunnelManager = profilerClusterTunnelManager
        profilerClusterTunnelManager = nil
        Task {
            await clusterTunnelManager?.disconnect()
        }
    }

    private func runProfiler(config: RedisConnectionConfig, generation: Int) async {
        // Holds the locally built stream until it is either published to shared
        // state (current generation) or disposed (superseded generation). It is
        // `nil` once ownership has been transferred to the shared properties.
        var profilerStream: RedisProfilerStream?

        defer {
            flushProfilerCaptures()
            if profilerGeneration == generation {
                profilerMonitorTasks?.cancelAll()
                for client in profilerMonitorClients {
                    client.disconnect()
                }
                profilerSSHTunnel?.stop()
                let clusterTunnelManager = profilerClusterTunnelManager

                profilerMonitorClients = []
                profilerMonitorTasks = nil
                profilerSSHTunnel = nil
                profilerClusterTunnelManager = nil
                profilerTask = nil
                isProfilerRunning = false
                isProfilerStarting = false

                await clusterTunnelManager?.disconnect()
            }
            if let stream = profilerStream {
                await disposeProfilerStream(stream)
            }
        }

        do {
            switch config.mode {
            case .standalone:
                profilerStream = try await startStandaloneProfilerStream(config: config)
            case .cluster:
                profilerStream = try await startClusterProfilerStream(config: config)
            }

            // A superseded generation (startProfiler/stopProfiler already advanced
            // the generation and cancelled this task) must not publish its
            // resources, otherwise it would overwrite the active generation's
            // references. Tear the local copy down instead.
            try Task.checkCancellation()
            guard profilerGeneration == generation, let stream = profilerStream else {
                return
            }

            profilerSSHTunnel = stream.tunnel
            profilerMonitorClients = stream.monitorClients
            profilerMonitorTasks = stream.monitorTasks
            profilerClusterTunnelManager = stream.tunnelManager
            profilerStream = nil

            isProfilerStarting = false
            isProfilerRunning = true
            if let nodeWarning = stream.nodeWarning {
                profilerError = nodeWarning
            }
            AppLogger.info("profiler started redis=\(config.address)", category: "Profiler")

            for try await capture in stream.stream {
                try Task.checkCancellation()
                appendProfilerCapture(capture)
            }

            AppLogger.info("profiler stopped redis=\(config.address)", category: "Profiler")
        } catch is CancellationError {
            AppLogger.info("profiler cancelled redis=\(config.address)", category: "Profiler")
        } catch {
            if profilerGeneration == generation {
                profilerError = error.localizedDescription
            }
            AppLogger.error("profiler failed redis=\(config.address) error=\(error)", category: "Profiler")
        }
    }

    /// Releases resources owned by a `RedisProfilerStream` that was built but
    /// never published to shared state (e.g. a cancelled, superseded generation).
    private func disposeProfilerStream(_ stream: RedisProfilerStream) async {
        stream.monitorTasks?.cancelAll()
        for client in stream.monitorClients {
            client.disconnect()
        }
        stream.tunnel?.stop()
        await stream.tunnelManager?.disconnect()
    }

    private func startStandaloneProfilerStream(
        config: RedisConnectionConfig
    ) async throws -> RedisProfilerStream {
        var connectHost = config.host
        var connectPort = config.port
        var tunnel: SSHTunnel?
        var monitorClient: RedisClient?

        // Build every resource locally and publish nothing to shared state here.
        // The caller publishes the returned stream once the generation is confirmed,
        // so a superseded (cancelled) task can never clobber the active generation's
        // references. Any failure path cleans up the locally owned resources.
        do {
            if config.ssh.enabled {
                let createdTunnel = try await SSHTunnel.connect(
                    config: config.ssh,
                    remoteHost: config.host,
                    remotePort: config.port
                )
                tunnel = createdTunnel
                connectHost = "127.0.0.1"
                connectPort = createdTunnel.localPort
            }

            try Task.checkCancellation()

            let (client, rawStream) = try await startProfilerMonitorStream(
                config: config,
                host: connectHost,
                port: connectPort,
                context: "Redis profiler connection"
            )
            monitorClient = client

            let (stream, continuation) = AsyncThrowingStream<RedisProfilerCapture, Error>.makeStream(
                of: RedisProfilerCapture.self,
                throwing: Error.self,
                bufferingPolicy: .bufferingNewest(profilerMaxEntries)
            )
            let taskBag = RedisProfilerTaskBag()
            taskBag.add(
                monitorStreamTask(
                    rawStream: rawStream,
                    node: nil,
                    continuation: continuation
                )
            )

            return RedisProfilerStream(
                stream: stream,
                monitorClients: [client],
                monitorTasks: taskBag,
                tunnel: tunnel,
                tunnelManager: nil
            )
        } catch {
            tunnel?.stop()
            monitorClient?.disconnect()
            throw error
        }
    }

    private func startClusterProfilerStream(
        config: RedisConnectionConfig
    ) async throws -> RedisProfilerStream {
        guard let client = activeSession, client.mode == .cluster else {
            throw RedisError.commandError("Profiler requires an active Redis Cluster connection")
        }

        let nodes = try await client.clusterNodes()
        let endpoints = RedisEndpoint.unique(nodes.map(\.endpoint))
        guard !endpoints.isEmpty else {
            throw RedisError.commandError("Redis Cluster topology has no nodes")
        }

        // Owned locally until the caller confirms the generation below.
        let tunnelManager = config.ssh.enabled ? SSHClusterTunnelManager(ssh: config.ssh) : nil

        let (stream, continuation) = AsyncThrowingStream<RedisProfilerCapture, Error>.makeStream(
            of: RedisProfilerCapture.self,
            throwing: Error.self,
            bufferingPolicy: .bufferingNewest(profilerMaxEntries)
        )
        let taskBag = RedisProfilerTaskBag()

        var monitorClients: [RedisClient] = []
        var nodeFailures: [(endpoint: RedisEndpoint, error: Error)] = []
        var didTransferOwnership = false

        defer {
            if !didTransferOwnership {
                for client in monitorClients {
                    client.disconnect()
                }
                taskBag.cancelAll()
                await tunnelManager?.disconnect()
            }
        }

        // A single bad node (unreachable, wrong password, stale topology
        // entry) must not kill MONITOR on the healthy nodes: connect per
        // node, keep whatever works, and report the rest with its address.
        for endpoint in endpoints {
            try Task.checkCancellation()

            do {
                let clientEndpoint: RedisEndpoint
                if let tunnelManager {
                    clientEndpoint = try await tunnelManager.clientEndpoint(for: endpoint)
                } else {
                    clientEndpoint = endpoint
                }

                let context = "Redis profiler connection to \(endpoint.address)"
                let (monitorClient, rawStream) = try await startProfilerMonitorStream(
                    config: config,
                    host: clientEndpoint.host,
                    port: clientEndpoint.port,
                    context: context
                )

                monitorClients.append(monitorClient)
                taskBag.add(
                    monitorStreamTask(
                        rawStream: rawStream,
                        node: endpoint,
                        continuation: continuation
                    )
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                nodeFailures.append((endpoint: endpoint, error: error))
                AppLogger.error(
                    "profiler node failed endpoint=\(endpoint.address) error=\(error)",
                    category: "Profiler")
            }
        }

        guard !monitorClients.isEmpty else {
            let details = nodeFailures.map { failure in
                "\(failure.endpoint.address): \(failure.error.localizedDescription)"
            }.joined(separator: "; ")
            throw RedisError.commandError(
                "Profiler could not MONITOR any of the \(endpoints.count) cluster nodes: \(details)"
            )
        }

        var nodeWarning: String?
        if !nodeFailures.isEmpty {
            let skipped = nodeFailures.map { failure in
                "\(failure.endpoint.address): \(failure.error.localizedDescription)"
            }.joined(separator: "; ")
            nodeWarning =
                "Profiler is monitoring \(monitorClients.count) of \(endpoints.count) cluster nodes. Skipped \(skipped)."
        }

        didTransferOwnership = true
        return RedisProfilerStream(
            stream: stream,
            monitorClients: monitorClients,
            monitorTasks: taskBag,
            tunnel: nil,
            tunnelManager: tunnelManager,
            nodeWarning: nodeWarning
        )
    }

    private func makeProfilerMonitorClient(
        config: RedisConnectionConfig,
        host: String,
        port: UInt16
    ) -> RedisClient {
        // A dedicated MONITOR connection per node: RESP2 with the plain AUTH
        // handshake (no HELLO), matching what MONITOR expects. Never send
        // other commands on it once monitoring starts.
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

    /// Opens one MONITOR connection, working around servers that reject a
    /// standalone AUTH while having no password at all (observed on Redis
    /// 8.8: `HELLO 3 AUTH` is silently accepted, plain `AUTH` fails): in that
    /// case only, retry the same node anonymously. Any other failure —
    /// including a genuinely wrong password (`WRONGPASS`) — propagates.
    /// Owns the client lifecycle: failures disconnect before throwing.
    private func startProfilerMonitorStream(
        config: RedisConnectionConfig,
        host: String,
        port: UInt16,
        context: String
    ) async throws -> (RedisClient, AsyncThrowingStream<String, Error>) {
        let client = makeProfilerMonitorClient(config: config, host: host, port: port)
        do {
            let stream = try await withTimeout(config.connectionTimeout, context: context) {
                try await client.startMonitoring()
            }
            return (client, stream)
        } catch {
            client.disconnect()
            guard sendsProfilerAuth(config), isNoPasswordConfiguredError(error) else {
                throw error
            }
            AppLogger.info(
                "profiler retrying without AUTH; server has no password configured",
                category: "Profiler",
                fields: ["context": context]
            )
            var anonymousConfig = config
            anonymousConfig.username = ""
            anonymousConfig.password = ""
            let anonymous = makeProfilerMonitorClient(config: anonymousConfig, host: host, port: port)
            do {
                let stream = try await withTimeout(config.connectionTimeout, context: context) {
                    try await anonymous.startMonitoring()
                }
                return (anonymous, stream)
            } catch {
                anonymous.disconnect()
                throw error
            }
        }
    }

    private func sendsProfilerAuth(_ config: RedisConnectionConfig) -> Bool {
        !config.username.isEmpty || !config.password.isEmpty
    }

    /// Matches the "server has no password" AUTH rejection across server
    /// versions: Redis 7+ reports "without any password configured", Redis 6
    /// and earlier report "no password is set".
    private func isNoPasswordConfiguredError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("without any password configured") || message.contains("no password is set")
    }

    private nonisolated func monitorStreamTask(
        rawStream: AsyncThrowingStream<String, Error>,
        node: RedisEndpoint?,
        continuation: AsyncThrowingStream<RedisProfilerCapture, Error>.Continuation
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await line in rawStream {
                    try Task.checkCancellation()
                    continuation.yield(RedisProfilerCapture(node: node, line: line))
                }

                if !Task.isCancelled {
                    continuation.finish(
                        throwing: RedisError.commandError("MONITOR connection ended unexpectedly"))
                }
            } catch is CancellationError {
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func appendProfilerCapture(_ capture: RedisProfilerCapture) {
        profilerPendingCaptures.append(capture)
        scheduleProfilerFlush()
    }

    /// Schedules a single delayed flush; lines arriving before it fires join
    /// the same batch, so one `@Observable` write covers the whole window.
    private func scheduleProfilerFlush() {
        guard profilerFlushTask == nil else { return }
        let generation = profilerGeneration
        profilerFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            // A stop/restart advanced the generation and already flushed (or
            // discarded) these lines synchronously; never touch newer state.
            guard generation == self.profilerGeneration else { return }
            self.flushProfilerCaptures()
        }
    }

    private func flushProfilerCaptures() {
        profilerFlushTask = nil
        guard !profilerPendingCaptures.isEmpty else { return }
        let pending = profilerPendingCaptures
        profilerPendingCaptures = []
        profilerCapturedCount += pending.count
        profilerEntries.append(contentsOf: pending.map { RedisProfilerEntry(rawLine: $0.line, node: $0.node) })

        if profilerEntries.count > profilerMaxEntries {
            // Slice off the excess in one pass; removeFirst(1) per entry was O(n²).
            profilerEntries.removeFirst(profilerEntries.count - profilerMaxEntries)
        }
    }
}
