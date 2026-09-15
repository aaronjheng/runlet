import Foundation

// MARK: - Connection Probe

/// Outcome of a connection probe. Carries values, not display strings:
/// formatting stays in the view.
enum ConnectionProbeOutcome {
    case success(latencyMs: Double, reply: String?)
    case failure(message: String)
    /// The probe was cancelled before it finished; no verdict.
    case cancelled
}

/// Standalone use case that verifies a connection config end to end:
/// SSH tunnel (when enabled), Redis connect, and a PING round trip.
///
/// Extracted from `ConnectionDetailView` so the view owns only form state
/// and result rendering. All tunnel/client resources are owned locally and
/// torn down in `run()`, so a probe can never leak into the tab's session.
struct ConnectionProbe {
    let config: RedisConnectionConfig

    func run() async -> ConnectionProbeOutcome {
        AppLogger.info(
            "test connection requested mode=\(config.mode.rawValue) redis=\(config.address) "
                + "sshEnabled=\(config.ssh.enabled) tlsEnabled=\(config.tls.enabled) "
                + "ssh=\(config.ssh.host):\(config.ssh.port) user=\(config.ssh.user)",
            category: "ConnectionTest"
        )
        var client: (any RedisSession)?
        var tunnel: SSHTunnel?
        var clusterTunnelManager: SSHClusterTunnelManager?
        defer {
            let manager = clusterTunnelManager
            client?.disconnect()
            tunnel?.stop()
            Task { await manager?.disconnect() }
        }

        do {
            try Task.checkCancellation()

            var connectHost = config.host
            var connectPort = config.port
            var clusterEndpointResolver: (any RedisClusterEndpointResolver)?

            if config.ssh.enabled {
                let trimmedSSHHost = config.ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedSSHUser = config.ssh.user.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveSSHUser = trimmedSSHUser.isEmpty ? NSUserName() : trimmedSSHUser
                guard !trimmedSSHHost.isEmpty else {
                    AppLogger.error("test failed: empty ssh host", category: "ConnectionTest")
                    return .failure(message: "SSH host is required")
                }

                switch config.mode {
                case .standalone:
                    do {
                        let createdTunnel = try await SSHTunnel.connect(
                            config: config.ssh,
                            remoteHost: config.host,
                            remotePort: config.port
                        )
                        tunnel = createdTunnel
                        connectHost = "127.0.0.1"
                        connectPort = createdTunnel.localPort
                        AppLogger.info(
                            "test ssh tunnel ready mode=\(createdTunnel.mode.rawValue) local=127.0.0.1:\(connectPort)",
                            category: "ConnectionTest"
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        AppLogger.error("test ssh tunnel failed error=\(error)", category: "ConnectionTest")
                        return .failure(message: "SSH tunnel: \(error.localizedDescription)")
                    }
                case .cluster:
                    let manager = SSHClusterTunnelManager(ssh: config.ssh)
                    clusterTunnelManager = manager
                    clusterEndpointResolver = manager
                    AppLogger.info(
                        "test cluster ssh tunnel manager ready ssh=\(trimmedSSHHost):\(config.ssh.port) user=\(effectiveSSHUser)",
                        category: "ConnectionTest"
                    )
                }
            }

            try Task.checkCancellation()

            let createdClient = makeRedisSession(
                config: config,
                host: connectHost,
                port: connectPort,
                seedNodes: [RedisEndpoint(host: connectHost, port: connectPort)],
                endpointResolver: clusterEndpointResolver
            )
            client = createdClient

            try await withTimeout(config.connectionTimeout, context: "Redis connection") {
                try await createdClient.connect()
            }
            try Task.checkCancellation()

            let start = Date()
            let pong = try await withTimeout(config.pingTimeout, context: "Redis PING") {
                try await createdClient.send("PING")
            }
            if case .error(let message) = pong {
                throw RedisError.commandError(message)
            }
            let elapsed = Date().timeIntervalSince(start) * 1000
            AppLogger.info("test succeeded result=\(pong.string ?? "PONG") elapsed=\(elapsed)ms", category: "ConnectionTest")
            return .success(latencyMs: elapsed, reply: pong.string)
        } catch is CancellationError {
            AppLogger.info("test cancelled", category: "ConnectionTest")
            return .cancelled
        } catch {
            AppLogger.error("test redis failed error=\(error)", category: "ConnectionTest")
            return .failure(message: error.localizedDescription)
        }
    }
}
