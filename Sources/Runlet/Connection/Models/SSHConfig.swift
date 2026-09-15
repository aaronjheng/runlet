import Foundation

// MARK: - SSH Tunnel Mode

/// How the SSH tunnel is established.
///
/// - `builtIn`: NIO-based SSH implementation inside the app. Supports
///   password and (unencrypted) Ed25519/ECDSA keys, but ignores the local
///   SSH infrastructure (`~/.ssh/config`, agents, ProxyJump, certificates).
/// - `external`: delegates to the local `/usr/bin/ssh`, so agent identities,
///   `~/.ssh/config` (including ProxyJump), `known_hosts` and certificates
///   work exactly like in Terminal. Tunnels to the same SSH destination
///   share one multiplexed master connection. Passwords are ignored in this
///   mode — use `ssh-agent` for passphrases.
enum SSHTunnelMode: String, Codable, Hashable, Sendable, CaseIterable {
    case builtIn
    case external

    var title: String {
        switch self {
        case .builtIn: return "Built-in"
        case .external: return "System SSH"
        }
    }
}

struct SSHConfig: Codable, Hashable {
    var enabled: Bool = false
    var mode: SSHTunnelMode = .builtIn
    var host: String = ""
    var port: UInt16 = 22
    var user: String = ""
    var password: String = ""
    var privateKeyPath: String = ""
    var privateKeyPassphrase: String = ""

    // Timeout settings (in seconds). Deliberately not persisted — there is no
    // UI to edit them, so stored values would freeze old defaults forever and
    // shipped fixes could never reach existing connections.
    // `setupTimeout` bounds the whole tunnel setup; it must be generous
    // because System SSH may run interactive flows (e.g. `tsh proxy` opening
    // a browser for login) that legitimately take minutes.
    var setupTimeout: TimeInterval = 180
    var connectionAttemptTimeout: TimeInterval = 10
    var maxConnectionAttempts: Int = 4
    var authTimeout: TimeInterval = 10

    enum CodingKeys: String, CodingKey {
        case enabled
        case mode
        case host
        case port
        case user
        case password
        case privateKeyPath
        case privateKeyPassphrase
    }

    init(
        enabled: Bool = false,
        mode: SSHTunnelMode = .builtIn,
        host: String = "",
        port: UInt16 = 22,
        user: String = "",
        password: String = "",
        privateKeyPath: String = "",
        privateKeyPassphrase: String = "",
        setupTimeout: TimeInterval = 180,
        connectionAttemptTimeout: TimeInterval = 10,
        maxConnectionAttempts: Int = 4,
        authTimeout: TimeInterval = 10
    ) {
        self.enabled = enabled
        self.mode = mode
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.privateKeyPassphrase = privateKeyPassphrase
        self.setupTimeout = setupTimeout
        self.connectionAttemptTimeout = connectionAttemptTimeout
        self.maxConnectionAttempts = maxConnectionAttempts
        self.authTimeout = authTimeout
    }

    // Custom decoding only to keep `CodingKeys` in control of the persisted
    // fields; every field is required and a missing key fails the decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        mode = try container.decode(SSHTunnelMode.self, forKey: .mode)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        user = try container.decode(String.self, forKey: .user)
        password = try container.decode(String.self, forKey: .password)
        privateKeyPath = try container.decode(String.self, forKey: .privateKeyPath)
        privateKeyPassphrase = try container.decode(String.self, forKey: .privateKeyPassphrase)
    }
}
