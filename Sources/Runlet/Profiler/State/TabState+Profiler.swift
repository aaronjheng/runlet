import Foundation

extension TabState {
    // MARK: - Profiler

    func startProfiler() {
        guard !isProfilerRunning && !isProfilerStarting else { return }
        guard let config = selectedConnection else {
            profilerError = "Connect to a Redis server before starting the profiler."
            return
        }

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
        profilerEntries = []
        profilerCapturedCount = 0
        profilerError = nil
    }

    private func cancelProfilerResources() {
        profilerTask?.cancel()
        profilerTask = nil

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
                if let stream = profilerStream {
                    disposeProfilerStream(stream)
                }
                return
            }

            profilerSSHTunnel = stream.tunnel
            profilerMonitorClients = stream.monitorClients
            profilerMonitorTasks = stream.monitorTasks
            profilerClusterTunnelManager = stream.tunnelManager
            profilerStream = nil

            isProfilerStarting = false
            isProfilerRunning = true
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

        // Tear down shared state when this generation is still the active one.
        // On natural exit this is the only teardown; on stopProfiler() the shared
        // state was already released by cancelProfilerResources(), so this is a
        // harmless no-op. When the generation was superseded before publishing,
        // the local stream is disposed below and shared state is untouched here.
        if profilerGeneration == generation {
            profilerMonitorTasks?.cancelAll()
            for client in profilerMonitorClients {
                client.disconnect()
            }
            profilerSSHTunnel?.stop()
            let clusterTunnelManager = profilerClusterTunnelManager
            Task { await clusterTunnelManager?.disconnect() }

            profilerMonitorClients = []
            profilerMonitorTasks = nil
            profilerSSHTunnel = nil
            profilerClusterTunnelManager = nil
            profilerTask = nil
            isProfilerRunning = false
            isProfilerStarting = false
        } else if let stream = profilerStream {
            // The stream was built but never published because this generation
            // was superseded/cancelled. Release its resources locally.
            disposeProfilerStream(stream)
        }
    }

    /// Releases resources owned by a `RedisProfilerStream` that was built but
    /// never published to shared state (e.g. a cancelled, superseded generation).
    private func disposeProfilerStream(_ stream: RedisProfilerStream) {
        stream.monitorTasks?.cancelAll()
        for client in stream.monitorClients {
            client.disconnect()
        }
        stream.tunnel?.stop()
        if let tunnelManager = stream.tunnelManager {
            Task { await tunnelManager.disconnect() }
        }
    }

    private func startStandaloneProfilerStream(
        config: RedisConnectionConfig
    ) async throws -> RedisProfilerStream {
        var connectHost = config.host
        var connectPort = config.port
        var tunnel: SSHTunnel?
        var monitorClient: RedisMonitorClient?

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

            let client = makeProfilerMonitorClient(config: config, host: connectHost, port: connectPort)
            monitorClient = client

            let rawStream = try await withTimeout(config.connectionTimeout, context: "Redis profiler connection") {
                try await client.startMonitoring()
            }

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

        var monitorClients: [RedisMonitorClient] = []

        do {
            for endpoint in endpoints {
                try Task.checkCancellation()

                let clientEndpoint: RedisEndpoint
                if let tunnelManager {
                    clientEndpoint = try await tunnelManager.clientEndpoint(for: endpoint)
                } else {
                    clientEndpoint = endpoint
                }

                let monitorClient = makeProfilerMonitorClient(config: config, host: clientEndpoint.host, port: clientEndpoint.port)
                monitorClients.append(monitorClient)

                let context = "Redis profiler connection to \(endpoint.address)"
                let rawStream = try await withTimeout(config.connectionTimeout, context: context) {
                    try await monitorClient.startMonitoring()
                }

                taskBag.add(
                    monitorStreamTask(
                        rawStream: rawStream,
                        node: endpoint,
                        continuation: continuation
                    )
                )
            }
        } catch {
            for client in monitorClients {
                client.disconnect()
            }
            taskBag.cancelAll()
            if let tunnelManager {
                Task { await tunnelManager.disconnect() }
            }
            throw error
        }

        return RedisProfilerStream(
            stream: stream,
            monitorClients: monitorClients,
            monitorTasks: taskBag,
            tunnel: nil,
            tunnelManager: tunnelManager
        )
    }

    private func makeProfilerMonitorClient(
        config: RedisConnectionConfig,
        host: String,
        port: UInt16
    ) -> RedisMonitorClient {
        RedisMonitorClient(
            host: host,
            port: port,
            username: config.username.isEmpty ? nil : config.username,
            password: config.password.isEmpty ? nil : config.password,
            tlsEnabled: config.tls.enabled,
            verifyServerCertificate: config.tls.verifyServerCertificate,
            caCertificatePath: config.tls.caCertificatePath,
            clientCertificatePath: config.tls.clientCertificatePath,
            clientKeyPath: config.tls.clientKeyPath,
            connectionTimeout: config.connectionTimeout
        )
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
        profilerCapturedCount += 1
        profilerEntries.append(RedisProfilerEntry(rawLine: capture.line, node: capture.node))

        if profilerEntries.count > profilerMaxEntries {
            // Slice off the excess in one pass; removeFirst(1) per entry was O(n²).
            profilerEntries.removeFirst(profilerEntries.count - profilerMaxEntries)
        }
    }
}
