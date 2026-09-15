import Foundation
import Synchronization

final class RedisClusterClient: RedisSession {
    struct ConnectionStatus: Sendable {
        var isConnected = false
        var lastError: String?
    }

    let seedNodes: [RedisEndpoint]
    let makeClient: @Sendable (RedisEndpoint) -> RedisClient
    let endpointResolver: (any RedisClusterEndpointResolver)?
    let state = RedisClusterState()
    let status = Mutex(ConnectionStatus())

    var isConnected: Bool {
        status.withLock { $0.isConnected }
    }

    var lastError: String? {
        status.withLock { $0.lastError }
    }

    var mode: RedisConnectionMode { .cluster }

    init(
        seedNodes: [RedisEndpoint],
        username: String? = nil,
        password: String? = nil,
        tlsEnabled: Bool = false,
        verifyServerCertificate: Bool = true,
        caCertificatePath: String = "",
        clientCertificatePath: String = "",
        clientKeyPath: String = "",
        preferredProtocolVersion: RESPProtocolVersion = .resp3,
        connectionTimeout: TimeInterval = 10,
        endpointResolver: (any RedisClusterEndpointResolver)? = nil
    ) {
        self.seedNodes = RedisEndpoint.unique(seedNodes)
        self.endpointResolver = endpointResolver
        self.makeClient = { endpoint in
            RedisClient(
                host: endpoint.host,
                port: endpoint.port,
                username: username,
                password: password,
                tlsEnabled: tlsEnabled,
                verifyServerCertificate: verifyServerCertificate,
                caCertificatePath: caCertificatePath,
                clientCertificatePath: clientCertificatePath,
                clientKeyPath: clientKeyPath,
                preferredProtocolVersion: preferredProtocolVersion,
                connectionTimeout: connectionTimeout
            )
        }
    }
    deinit {
        disconnect(publishState: false)
    }

    func connect() async throws {
        guard !seedNodes.isEmpty else {
            throw RedisError.commandError("At least one Redis Cluster seed node is required")
        }

        do {
            try await refreshTopology(preferredEndpoint: seedNodes.first)
            let primaries = await state.primaryEndpoints()
            guard !primaries.isEmpty else {
                throw RedisError.commandError("Redis Cluster topology has no primary nodes")
            }
            updateConnectionStatus(isConnected: true, lastError: nil)
        } catch {
            updateConnectionStatus(isConnected: false, lastError: error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        disconnect(publishState: true)
    }

    private func disconnect(publishState: Bool) {
        if publishState {
            updateConnectionStatus(isConnected: false)
        }
        let state = state
        let endpointResolver = endpointResolver
        Task {
            await state.disconnectAll()
            await endpointResolver?.disconnect()
        }
    }

    private func updateConnectionStatus(isConnected: Bool? = nil, lastError: String? = nil) {
        status.withLock {
            if let isConnected {
                $0.isConnected = isConnected
            }
            $0.lastError = lastError
        }
    }
}
