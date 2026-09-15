import Foundation

extension TabState {
    // MARK: - Connect / Disconnect

    func connect(to config: RedisConnectionConfig) async {
        let resolvedConfig = config
        AppLogger.info(
            "connect requested name=\(resolvedConfig.name) "
                + "mode=\(resolvedConfig.mode.rawValue) redis=\(resolvedConfig.address) "
                + "sshEnabled=\(resolvedConfig.ssh.enabled) tlsEnabled=\(resolvedConfig.tls.enabled)",
            category: "Connection"
        )
        stopProfiler(clearEntries: true)
        connectTask?.cancel()
        activeSession?.disconnect()
        sshTunnel?.stop()
        sshTunnel = nil
        let previousClusterTunnelManager = sshClusterTunnelManager
        sshClusterTunnelManager = nil
        await previousClusterTunnelManager?.disconnect()

        isConnecting = true
        connectionError = nil
        pendingConnection = resolvedConfig
        resetForDisconnect()
        connectGeneration += 1
        let generation = connectGeneration

        let task = Task { @MainActor in
            var connectHost = resolvedConfig.host
            var connectPort = resolvedConfig.port
            var client: (any RedisSession)?
            var clusterTunnelManager: SSHClusterTunnelManager?

            do {
                var clusterEndpointResolver: (any RedisClusterEndpointResolver)?

                if resolvedConfig.ssh.enabled {
                    let sshHost = resolvedConfig.ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sshUser = resolvedConfig.ssh.user.trimmingCharacters(in: .whitespacesAndNewlines)
                    let effectiveSSHUser = sshUser.isEmpty ? NSUserName() : sshUser
                    guard !sshHost.isEmpty else {
                        throw SSHTunnelError.connectionFailed("SSH host is required")
                    }

                    switch resolvedConfig.mode {
                    case .standalone:
                        AppLogger.info(
                            "starting ssh tunnel ssh=\(sshHost):\(resolvedConfig.ssh.port) "
                                + "user=\(effectiveSSHUser) remote=\(resolvedConfig.host):\(resolvedConfig.port)",
                            category: "Connection"
                        )
                        let tunnel = try await SSHTunnel.connect(
                            config: resolvedConfig.ssh,
                            remoteHost: resolvedConfig.host,
                            remotePort: resolvedConfig.port
                        )
                        sshTunnel = tunnel
                        connectHost = "127.0.0.1"
                        connectPort = tunnel.localPort
                        AppLogger.info(
                            "ssh tunnel ready mode=\(tunnel.mode.rawValue) local=127.0.0.1:\(connectPort)",
                            category: "Connection"
                        )
                    case .cluster:
                        let manager = SSHClusterTunnelManager(ssh: resolvedConfig.ssh)
                        clusterTunnelManager = manager
                        sshClusterTunnelManager = manager
                        clusterEndpointResolver = manager
                        AppLogger.info(
                            "cluster ssh tunnel manager ready ssh=\(sshHost):\(resolvedConfig.ssh.port) "
                                + "user=\(effectiveSSHUser)",
                            category: "Connection"
                        )
                    }
                }

                try Task.checkCancellation()

                let redis = makeRedisSession(
                    config: resolvedConfig,
                    host: connectHost,
                    port: connectPort,
                    seedNodes: resolvedConfig.effectiveSeedNodes,
                    endpointResolver: clusterEndpointResolver
                )
                client = redis

                try await withTimeout(resolvedConfig.connectionTimeout, context: "Redis connection") {
                    try await redis.connect()
                }
                AppLogger.info("redis connected mode=\(resolvedConfig.mode.rawValue) \(resolvedConfig.address)", category: "Connection")

                try Task.checkCancellation()

                activeSession = redis
                selectedConnection = resolvedConfig
                loadShellHistory(for: resolvedConfig)
                isConnecting = false
                pendingConnection = nil
                await loadServerInfo()
                await scanKeys(reset: true)
                await connectShellClient()
                AppLogger.info("connect completed name=\(resolvedConfig.name)", category: "Connection")
            } catch is CancellationError {
                client?.disconnect()
                // Only tear down shared state when this task is still the
                // current connect; a superseded task must leave the new
                // connection's resources alone.
                if generation == self.connectGeneration {
                    clearClusterTunnelManagerIfCurrent(clusterTunnelManager)
                }
                if let clusterTunnelManager {
                    await clusterTunnelManager.disconnect()
                }
                AppLogger.info("connect cancelled name=\(resolvedConfig.name)", category: "Connection")
            } catch {
                client?.disconnect()
                if generation == self.connectGeneration {
                    connectionError = error.localizedDescription
                    failedConnection = resolvedConfig
                    isConnecting = false
                    pendingConnection = nil
                    sshTunnel?.stop()
                    sshTunnel = nil
                }
                clearClusterTunnelManagerIfCurrent(clusterTunnelManager)
                if let clusterTunnelManager {
                    await clusterTunnelManager.disconnect()
                }
                let stage = (client == nil) ? "ssh-tunnel" : "redis-connect"
                let errorType = type(of: error)
                AppLogger.error(
                    "connect failed name=\(resolvedConfig.name) stage=\(stage) errorType=\(errorType) error=\(error)",
                    category: "Connection"
                )
            }
        }

        connectTask = task
        await task.value
    }

    private func clearClusterTunnelManagerIfCurrent(_ manager: SSHClusterTunnelManager?) {
        guard let current = sshClusterTunnelManager, let manager else { return }
        guard ObjectIdentifier(current) == ObjectIdentifier(manager) else { return }
        sshClusterTunnelManager = nil
    }

    func cancelConnection() {
        AppLogger.info("cancel connection", category: "Connection")
        stopProfiler(clearEntries: true)
        connectTask?.cancel()
        connectTask = nil
        activeSession?.disconnect()
        activeSession = nil
        sshTunnel?.stop()
        sshTunnel = nil
        let clusterTunnelManager = sshClusterTunnelManager
        sshClusterTunnelManager = nil
        Task { await clusterTunnelManager?.disconnect() }
        isConnecting = false
        pendingConnection = nil
        connectionError = nil
        resetForDisconnect()
    }

    func disconnect() {
        AppLogger.info("disconnect current connection", category: "Connection")
        stopProfiler(clearEntries: true)
        disconnectShellClient()
        connectTask?.cancel()
        connectTask = nil
        activeSession?.disconnect()
        activeSession = nil
        sshTunnel?.stop()
        sshTunnel = nil
        let clusterTunnelManager = sshClusterTunnelManager
        sshClusterTunnelManager = nil
        Task { await clusterTunnelManager?.disconnect() }
        selectedConnection = nil
        isConnecting = false
        pendingConnection = nil
        connectionError = nil
        resetForDisconnect()
    }

    /// Clears all per-connection UI state so a new connection starts fresh
    /// without stale data from the previous one. Shared by `disconnect()` and
    /// `cancelConnection()` to keep both paths consistent.
    private func resetForDisconnect() {
        // Keys
        keys = []
        selectedKey = nil
        scanCursor = "0"
        hasMoreKeys = true
        keyTotalCount = nil
        keyScannedCount = 0
        keyScanIterationCount = 0
        keyScanLimitReached = false
        keyFilter = "*"

        // Key detail
        keyDetail = ""
        keyDetailRows = []
        keyType = ""
        valueSize = nil
        keyDetailTotalCount = nil
        keyDetailError = nil
        keyDetailOffset = 0
        keyDetailCursor = "0"
        keyDetailHasMoreRows = false
        keyDetailSearchText = ""
        keyDetailLastRefreshedAt = nil
        isLoadingDetail = false
        isLoadingKeys = false

        // Shell
        shellInput = ""
        shellHistory = []
        shellHistoryConnectionID = nil

        // Server info
        serverInfo = [:]
        serverCapabilities = []
        clusterInfo = [:]
        clusterNodes = []
        selectedServerInfoNode = nil

        // Slow log
        slowLogEntries = []
        slowLogError = nil
        isLoadingSlowLog = false

        // Database analysis
        analysis = nil
        analysisError = nil
        analysisGeneration += 1
        isLoadingAnalysis = false
        analysisTask?.cancel()
        analysisTask = nil
        analysisTaskHandle?.cancel()
        analysisTaskHandle = nil

        // Functions
        functionLibraries = []
        functionsError = nil
        isLoadingFunctions = false
        selectedFunctionLibrary = nil
        functionCallHistory = []
        isCallingFunction = false
    }
}
