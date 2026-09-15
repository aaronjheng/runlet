import Crypto
import Foundation
import NIO
import NIOCore
@preconcurrency import NIOSSH
import NIOTransportServices
import Network
import Synchronization

class SSHTunnel: @unchecked Sendable {
    enum TunnelMode: String {
        case nioSSH
        case systemSSH
    }

    // Configurable timeout settings
    var setupTimeoutSeconds: TimeInterval = 30
    var connectionAttemptTimeout: TimeAmount = .seconds(10)
    var maxConnectionAttempts = 4
    var authTimeoutSeconds: TimeInterval = 10
    private var connectionRetryDelaysNanoseconds: [UInt64] = [
        300_000_000,
        800_000_000,
        1_600_000_000,
    ]

    /// Mutable tunnel runtime state, guarded by a single lock. The SSH config
    /// properties below stay plain vars: they are written once by `start()`
    /// before any concurrent access begins.
    private struct State {
        var group: NIOTSEventLoopGroup?
        var ownsGroup = true
        var channel: Channel?
        var localServer: Channel?
        var systemTunnel: SystemSSHTunnel?
        var localPort: UInt16 = 0
        var isRunning = false
        var mode: TunnelMode = .nioSSH
    }

    private let state = Mutex(State())

    /// Resources detached from the tunnel in `stop()`, returned while the
    /// state lock is held so teardown happens outside of it.
    private struct StoppedTunnel {
        var localServer: Channel?
        var channel: Channel?
        var ownedGroup: NIOTSEventLoopGroup?
        var systemTunnel: SystemSSHTunnel?
    }

    private(set) var localPort: UInt16 {
        get { state.withLock { $0.localPort } }
        set { state.withLock { $0.localPort = newValue } }
    }

    private(set) var isRunning: Bool {
        get { state.withLock { $0.isRunning } }
        set { state.withLock { $0.isRunning = newValue } }
    }

    private(set) var mode: TunnelMode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    // SSH configuration
    private var sshHost: String = ""
    private var sshPort: UInt16 = 22
    private var sshUser: String = ""
    private var sshPassword: String?
    private var privateKeyPath: String?
    private var remoteHost: String = ""
    private var remotePort: UInt16 = 6379

    private var effectiveSSHUser: String {
        let trimmedUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUser.isEmpty {
            return trimmedUser
        }
        return NSUserName()
    }

    // swiftlint:disable:next function_parameter_count
    func start(
        sshHost: String,
        sshPort: UInt16,
        sshUser: String,
        sshPassword: String?,
        privateKeyPath: String?,
        remoteHost: String,
        remotePort: UInt16,
        mode: SSHTunnelMode = .builtIn,
        eventLoopGroup: NIOTSEventLoopGroup? = nil
    ) async throws {
        let effectiveUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSUserName() : sshUser
        AppLogger.info(
            "start requested ssh=\(sshHost):\(sshPort) user=\(effectiveUser) "
                + "remote=\(remoteHost):\(remotePort) hasPassword=\(!(sshPassword ?? "").isEmpty) " + "keyPath=\(privateKeyPath ?? "")",
            category: "SSHTunnel"
        )
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUser = sshUser
        self.sshPassword = sshPassword
        self.privateKeyPath = privateKeyPath
        self.remoteHost = remoteHost
        self.remotePort = remotePort

        // External mode delegates to the local ssh(1) binary (agent,
        // ~/.ssh/config, ProxyJump, multiplexed master) instead of NIOSSH.
        if mode == .external {
            try await startViaSystemSSH()
            return
        }

        // Find available local port
        self.localPort = findAvailablePort()

        // Create Network.framework-backed event loop group, or reuse an injected one.
        let group: NIOTSEventLoopGroup
        if let eventLoopGroup {
            group = eventLoopGroup
            state.withLock {
                $0.group = group
                $0.ownsGroup = false
            }
        } else {
            group = NIOTSEventLoopGroup(loopCount: 1)
            state.withLock {
                $0.group = group
                $0.ownsGroup = true
            }
        }

        do {
            AppLogger.info("starting tunnel mode=nioSSH", category: "SSHTunnel")
            // Connect SSH channel
            let sshChannel = try await connectSSHWithRetry(group: group)
            state.withLock { $0.channel = sshChannel }

            // Start local TCP server
            let localServer = try await startLocalServer(group: group, sshChannel: sshChannel)
            state.withLock { $0.localServer = localServer }

            state.withLock {
                $0.mode = .nioSSH
                $0.isRunning = true
            }
            AppLogger.info("tunnel mode=nioSSH ready local=127.0.0.1:\(localPort)", category: "SSHTunnel")
        } catch {
            AppLogger.error("start failed error=\(error)", category: "SSHTunnel")
            let ownedGroup = state.withLock { state -> NIOTSEventLoopGroup? in
                defer { state.group = nil }
                return state.ownsGroup ? state.group : nil
            }
            if let ownedGroup {
                try? await ownedGroup.shutdownGracefully()
            }
            throw error
        }
    }

    func stop() {
        let stopped = state.withLock { state -> StoppedTunnel in
            state.isRunning = false
            let ownedGroup = state.ownsGroup ? state.group : nil
            state.group = nil
            let systemTunnel = state.systemTunnel
            state.systemTunnel = nil
            defer {
                state.localServer = nil
                state.channel = nil
            }
            return StoppedTunnel(
                localServer: state.localServer,
                channel: state.channel,
                ownedGroup: ownedGroup,
                systemTunnel: systemTunnel
            )
        }
        AppLogger.info("stop tunnel mode=\(mode.rawValue)", category: "SSHTunnel")

        // Release the system-ssh forwarding (the shared master survives
        // while other tunnels still use it).
        stopped.systemTunnel?.stop()

        // Close local server
        stopped.localServer?.close(promise: nil)

        // Close SSH channel
        stopped.channel?.close(promise: nil)

        // Shutdown event loop group asynchronously to avoid blocking the caller.
        // syncShutdownGracefully() can block the calling thread, which is
        // problematic when called from the main actor or a Task.
        if let ownedGroup = stopped.ownedGroup {
            Task {
                try? await ownedGroup.shutdownGracefully()
            }
        }
    }

    // MARK: - SSH Connection

    /// External-mode entry point: one `-O forward` lease on the shared
    /// system-ssh master connection (see `SystemSSHConnectionPool`).
    ///
    /// The raw `sshUser` is passed through (not `effectiveSSHUser`): an empty
    /// user lets `~/.ssh/config` supply `User`, exactly like in Terminal.
    private func startViaSystemSSH() async throws {
        // Publish the mode first so stop()/logs report correctly even when
        // the attempt below fails.
        state.withLock { $0.mode = .systemSSH }
        let systemTunnel = SystemSSHTunnel()
        systemTunnel.setupTimeoutSeconds = setupTimeoutSeconds
        do {
            try await systemTunnel.start(
                sshHost: sshHost,
                sshPort: sshPort,
                sshUser: sshUser,
                sshPassword: sshPassword,
                privateKeyPath: privateKeyPath,
                remoteHost: remoteHost,
                remotePort: remotePort
            )
        } catch {
            AppLogger.error("start via system ssh failed error=\(error)", category: "SSHTunnel")
            throw error
        }
        state.withLock {
            $0.systemTunnel = systemTunnel
            $0.localPort = systemTunnel.localPort
            $0.mode = .systemSSH
            $0.isRunning = true
        }
        AppLogger.info("tunnel mode=systemSSH ready local=127.0.0.1:\(systemTunnel.localPort)", category: "SSHTunnel")
    }

    private func connectSSHWithRetry(group: NIOTSEventLoopGroup) async throws -> Channel {
        var lastError: Error?

        for attempt in 1...maxConnectionAttempts {
            try Task.checkCancellation()

            do {
                return try await connectSSH(group: group)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let mappedError = mappedSSHError(error)
                lastError = mappedError

                guard attempt < maxConnectionAttempts, isRetriableConnectionError(error) else {
                    throw mappedError
                }

                let retryDelay = connectionRetryDelayNanoseconds(after: attempt)
                AppLogger.warn(
                    "ssh connect attempt failed ssh=\(sshHost):\(sshPort) "
                        + "attempt=\(attempt)/\(maxConnectionAttempts) "
                        + "retryInMs=\(retryDelay / 1_000_000) error=\(mappedError)",
                    category: "SSHTunnel"
                )
                try await Task.sleep(for: .nanoseconds(Int64(retryDelay)))
            }
        }

        throw lastError ?? SSHTunnelError.connectionFailed("SSH connection failed")
    }

    private func connectSSH(group: NIOTSEventLoopGroup) async throws -> Channel {
        let authDelegate = SSHAuthDelegateBox(value: createAuthDelegate())
        let serverHostKeyDelegate = SSHServerAuthDelegateBox(value: AcceptAllServerHostKeysDelegate())
        let handshakePromise = group.next().makePromise(of: Void.self)

        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(connectionAttemptTimeout)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(
                        .init(
                            userAuthDelegate: authDelegate.value,
                            serverAuthDelegate: serverHostKeyDelegate.value
                        )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )

                do {
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandlers([
                        HandshakeHandler(promise: handshakePromise),
                        ErrorHandler(),
                    ])
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        do {
            let channel = try await bootstrap.connect(host: sshHost, port: Int(sshPort)).get()

            // Wait for SSH authentication to complete.
            do {
                try await withTimeout(authTimeoutSeconds, context: "SSH authentication") {
                    try await handshakePromise.futureResult.get()
                }
            } catch {
                channel.close(promise: nil)
                AppLogger.error("ssh auth failed error=\(error)", category: "SSHTunnel")
                throw mappedSSHError(error)
            }

            return channel
        } catch {
            throw mappedSSHError(error)
        }
    }

    private func connectionRetryDelayNanoseconds(after attempt: Int) -> UInt64 {
        let index = max(0, min(attempt - 1, connectionRetryDelaysNanoseconds.count - 1))
        return connectionRetryDelaysNanoseconds[index]
    }

    private func isRetriableConnectionError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let connectionError = error as? NIOConnectionError {
            if !connectionError.connectionErrors.isEmpty {
                return connectionError.connectionErrors.allSatisfy {
                    isRetriableConnectionError($0.error)
                }
            }

            return isLocalHostname(sshHost)
                && (connectionError.dnsAError != nil || connectionError.dnsAAAAError != nil)
        }

        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return true
        }

        if let nwError = error as? NWError {
            return isRetriableNWError(nwError)
        }

        if let posixError = error as? POSIXError {
            return isRetriableErrno(posixError.code.rawValue)
        }

        guard let ioError = error as? IOError else { return false }
        return isRetriableErrno(ioError.errnoCode)
    }

    private func isLocalHostname(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".local")
    }

    private func isRetriableNWError(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code):
            return isRetriableErrno(code.rawValue)
        case .dns:
            return isLocalHostname(sshHost)
        case .tls:
            return false
        @unknown default:
            return false
        }
    }

    private func isRetriableErrno(_ errnoCode: CInt) -> Bool {
        switch errnoCode {
        case ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ETIMEDOUT, EADDRNOTAVAIL:
            return true
        default:
            return false
        }
    }

    private func mappedSSHError(_ error: Error) -> Error {
        guard let sshError = error as? NIOSSHError else {
            return error
        }

        if sshError.type == .keyExchangeNegotiationFailure {
            return SSHTunnelError.connectionFailed(
                "SSH algorithm negotiation failed. Server needs modern algorithms: "
                    + "KEX curve25519/ecdh, host key ssh-ed25519 or ecdsa-sha2-*, "
                    + "cipher aes128-gcm@openssh.com or aes256-gcm@openssh.com."
            )
        }

        return error
    }

    private func createAuthDelegate() -> NIOSSHClientUserAuthenticationDelegate {
        if let password = sshPassword, !password.isEmpty {
            return PasswordAuthDelegate(username: effectiveSSHUser, password: password)
        } else if let keyPath = privateKeyPath, !keyPath.isEmpty {
            let expandedPath = (keyPath as NSString).expandingTildeInPath
            return KeyAuthDelegate(username: effectiveSSHUser, keyPath: expandedPath)
        } else {
            // Try default key locations
            return KeyAuthDelegate(username: effectiveSSHUser, keyPath: nil)
        }
    }

    // MARK: - Local TCP Server

    private func startLocalServer(group: NIOTSEventLoopGroup, sshChannel: Channel) async throws -> Channel {
        let sshHandler = try await sshChannel.pipeline.handler(type: NIOSSHHandler.self)
            .map { SSHHandlerBox(value: $0) }
            .get()

        let bootstrap = NIOTSListenerBootstrap(group: group)
            .serverChannelOption(NIOTSChannelOptions.allowLocalEndpointReuse, value: true)
            .childChannelInitializer { channel in
                self.forwardToSSHChannel(
                    localChannel: channel,
                    sshHandler: sshHandler.value,
                    sshChannel: sshChannel
                )
            }

        let server = try await bootstrap.bind(host: "127.0.0.1", port: Int(localPort)).get()

        // Update localPort in case it was 0 (system-assigned)
        if let localAddress = server.localAddress {
            self.localPort = UInt16(localAddress.port ?? Int(self.localPort))
        }

        return server
    }

    private func forwardToSSHChannel(
        localChannel: Channel,
        sshHandler: NIOSSHHandler,
        sshChannel: Channel
    ) -> EventLoopFuture<Void> {
        // Create a direct-tcpip channel through SSH
        let promise = localChannel.eventLoop.makePromise(of: Channel.self)

        do {
            let originator = try localChannel.localAddress ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)

            let channelType: SSHChannelType = .directTCPIP(
                .init(
                    targetHost: remoteHost,
                    targetPort: Int(remotePort),
                    originatorAddress: originator
                )
            )

            sshHandler.createChannel(promise, channelType: channelType) { childChannel, _ in
                childChannel.pipeline.addHandlers([
                    SSHWrapperHandler(),
                    ErrorHandler(),
                ])
            }
        } catch {
            return localChannel.eventLoop.makeFailedFuture(error)
        }

        return promise.futureResult.flatMap { sshChildChannel in
            // Set up bidirectional forwarding
            let localToSSH = localChannel.pipeline.addHandler(
                DataForwarder(target: sshChildChannel)
            )
            let sshToLocal = sshChildChannel.pipeline.addHandler(
                DataForwarder(target: localChannel)
            )

            return localToSSH.and(sshToLocal).flatMap { _ in
                // Start reading
                _ = localChannel.setOption(ChannelOptions.autoRead, value: true)
                _ = sshChildChannel.setOption(ChannelOptions.autoRead, value: true)

                localChannel.closeFuture.whenComplete { _ in
                    sshChildChannel.close(promise: nil)
                }

                sshChildChannel.closeFuture.whenComplete { _ in
                    localChannel.close(promise: nil)
                }

                return localChannel.eventLoop.makeSucceededFuture(())
            }
        }
    }

    // MARK: - Helper Methods

    private func findAvailablePort() -> UInt16 {
        // Ask the OS for a free port by binding an ephemeral listener, then
        // close it. This avoids both the check-then-use race of scanning
        // random candidates and the unvalidated fallback port.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return UInt16.random(in: 10000..<60000) }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return UInt16.random(in: 10000..<60000) }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(sock, $0, &length)
            }
        }
        guard nameResult == 0 else { return UInt16.random(in: 10000..<60000) }
        return UInt16(bigEndian: assigned.sin_port)
    }

    private func isPortAvailable(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    deinit {
        stop()
    }
}

// MARK: - Error Types

enum SSHTunnelError: LocalizedError {
    case authMethodNotSupported
    case noPrivateKeyFound
    case keyTypeNotSupported(String)
    case invalidKeyFormat
    case handshakeFailed(String)
    case tunnelClosed
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .authMethodNotSupported:
            return "SSH authentication method not supported by server"
        case .noPrivateKeyFound:
            return "No SSH private key found. Please specify a key path or use password authentication."
        case .keyTypeNotSupported(let type):
            return "\(type) key type is not currently supported. Please use Ed25519 keys."
        case .invalidKeyFormat:
            return "Invalid SSH private key format"
        case .handshakeFailed(let msg):
            return "SSH handshake failed: \(msg)"
        case .tunnelClosed:
            return "SSH tunnel closed unexpectedly"
        case .connectionFailed(let msg):
            return "SSH connection failed: \(msg)"
        }
    }
}
