import Foundation
import Network
import Synchronization

final class RedisClient: Sendable {
    struct State: Sendable {
        var connection: NWConnection?
        var pendingCompletions: [PendingResponse] = []
        var parser = RESPParser()
        var isConnected = false
        var lastError: String?
        var negotiatedProtocolVersion: RESPProtocolVersion = .resp2
        var serverCapabilities: [String: RESPValue] = [:]
        var protocolFallbackReason: String?
        var pushHandler: (@Sendable (RESPValue) -> Void)?
        var handshakeTask: Task<Void, Never>?
    }

    let state = Mutex(State())
    let queue = DispatchQueue(label: "redis.client.queue")
    let queueKey = DispatchSpecificKey<Bool>()
    let tlsValidationQueue = DispatchQueue(label: "redis.client.tls-validation")

    var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    var lastError: String? {
        state.withLock { $0.lastError }
    }

    let host: String
    let port: UInt16
    let username: String?
    let password: String?
    let tlsEnabled: Bool
    let verifyServerCertificate: Bool
    let caCertificatePath: String
    let clientCertificatePath: String
    let clientKeyPath: String
    let preferredProtocolVersion: RESPProtocolVersion
    let connectionTimeout: TimeInterval
    /// Per-command timeout (not applied to blocking commands like BLPOP).
    let commandTimeout: TimeInterval

    /// Client TLS identity (certificate + private key). Retained for the
    /// connection's lifetime and released on disconnect; its temporary keychain
    /// must stay alive so the `sec_identity_t` keeps referencing the key.
    let clientIdentityBundle = Mutex<LoadedClientIdentity?>(nil)

    var negotiatedProtocolVersion: RESPProtocolVersion {
        get { state.withLock { $0.negotiatedProtocolVersion } }
        set { state.withLock { $0.negotiatedProtocolVersion = newValue } }
    }

    var serverCapabilities: [String: RESPValue] {
        get { state.withLock { $0.serverCapabilities } }
        set { state.withLock { $0.serverCapabilities = newValue } }
    }

    var protocolFallbackReason: String? {
        get { state.withLock { $0.protocolFallbackReason } }
        set { state.withLock { $0.protocolFallbackReason = newValue } }
    }

    init(
        host: String,
        port: UInt16,
        username: String? = nil,
        password: String? = nil,
        tlsEnabled: Bool = false,
        verifyServerCertificate: Bool = true,
        caCertificatePath: String = "",
        clientCertificatePath: String = "",
        clientKeyPath: String = "",
        preferredProtocolVersion: RESPProtocolVersion = .resp3,
        connectionTimeout: TimeInterval = 10,
        commandTimeout: TimeInterval = 30
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.tlsEnabled = tlsEnabled
        self.verifyServerCertificate = verifyServerCertificate
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
        self.preferredProtocolVersion = preferredProtocolVersion
        self.connectionTimeout = connectionTimeout
        self.commandTimeout = commandTimeout
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        disconnect(publishState: false)
    }
}
