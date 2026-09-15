import Foundation

struct RedisConnectionConfig: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var mode: RedisConnectionMode = .standalone
    var host: String
    var port: UInt16 = 6379
    var seedNodes: [RedisEndpoint] = []

    var username: String = ""
    var password: String = ""

    var ssh: SSHConfig = SSHConfig()
    var tls: TLSConfig = TLSConfig()
    var environment: ConnectionEnvironment = .unspecified

    // Timeout settings (in seconds)
    var connectionTimeout: TimeInterval = 10
    var pingTimeout: TimeInterval = 5

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mode
        case host
        case port
        case seedNodes
        case username
        case ssh
        case password
        case tls
        case environment
        case connectionTimeout
        case pingTimeout
    }

    static let `default` = RedisConnectionConfig(name: "localhost", host: "127.0.0.1")

    var effectiveSeedNodes: [RedisEndpoint] {
        [RedisEndpoint(host: host, port: port)]
    }

    var address: String {
        switch mode {
        case .standalone:
            return "\(host):\(port)"
        case .cluster:
            return effectiveSeedNodes.map(\.address).joined(separator: ", ")
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        mode: RedisConnectionMode = .standalone,
        host: String,
        port: UInt16 = 6379,
        seedNodes: [RedisEndpoint] = [],
        username: String = "",
        password: String = "",
        ssh: SSHConfig = SSHConfig(),
        tls: TLSConfig = TLSConfig(),
        environment: ConnectionEnvironment = .unspecified,
        connectionTimeout: TimeInterval = 10,
        pingTimeout: TimeInterval = 5
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.host = host
        self.port = port
        self.seedNodes = seedNodes
        self.username = username
        self.password = password
        self.ssh = ssh
        self.tls = tls
        self.environment = environment
        self.connectionTimeout = connectionTimeout
        self.pingTimeout = pingTimeout
    }

    static func parseURI(_ uri: String) -> RedisConnectionConfig? {
        guard let components = URLComponents(string: uri),
            let scheme = components.scheme,
            scheme == "redis" || scheme == "rediss"
        else { return nil }

        let host = components.host ?? "127.0.0.1"
        let port = UInt16(components.port ?? 6379)
        let useTLS = scheme == "rediss"

        var username = ""
        var password = ""

        if let pwd = components.password {
            username = components.user ?? ""
            password = pwd
        } else if let user = components.user {
            password = user
        }

        return RedisConnectionConfig(
            name: host,
            mode: .standalone,
            host: host,
            port: port,
            seedNodes: [],
            username: username,
            password: password,
            tls: TLSConfig(enabled: useTLS)
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(RedisConnectionMode.self, forKey: .mode)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        seedNodes = try container.decode([RedisEndpoint].self, forKey: .seedNodes)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        ssh = try container.decode(SSHConfig.self, forKey: .ssh)
        tls = try container.decode(TLSConfig.self, forKey: .tls)
        environment = try container.decode(ConnectionEnvironment.self, forKey: .environment)
        connectionTimeout = try container.decode(TimeInterval.self, forKey: .connectionTimeout)
        pingTimeout = try container.decode(TimeInterval.self, forKey: .pingTimeout)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode, forKey: .mode)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(seedNodes, forKey: .seedNodes)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(ssh, forKey: .ssh)
        try container.encode(tls, forKey: .tls)
        try container.encode(environment, forKey: .environment)
        try container.encode(connectionTimeout, forKey: .connectionTimeout)
        try container.encode(pingTimeout, forKey: .pingTimeout)
    }
}
