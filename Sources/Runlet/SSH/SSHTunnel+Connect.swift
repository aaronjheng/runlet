import Foundation

extension SSHTunnel {
    /// Starts a standalone tunnel from an SSH config, bounded by the config's
    /// own setup timeout.
    ///
    /// The single shared constructor behind the main connection, the shell
    /// session, the profiler, and the connection probe: maps the config's
    /// timeouts onto the tunnel, starts it, and stops it again on failure so
    /// callers never receive a half-started instance.
    static func connect(
        config: SSHConfig,
        remoteHost: String,
        remotePort: UInt16
    ) async throws -> SSHTunnel {
        let sshHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sshHost.isEmpty else {
            throw SSHTunnelError.connectionFailed("SSH host is required")
        }
        let tunnel = SSHTunnel()
        tunnel.setupTimeoutSeconds = config.setupTimeout
        tunnel.connectionAttemptTimeout = .seconds(Int64(config.connectionAttemptTimeout))
        tunnel.maxConnectionAttempts = config.maxConnectionAttempts
        tunnel.authTimeoutSeconds = config.authTimeout
        do {
            try await withTimeout(config.setupTimeout, context: "SSH tunnel setup") {
                try await tunnel.start(
                    sshHost: sshHost,
                    sshPort: config.port,
                    sshUser: config.user,
                    sshPassword: config.password.isEmpty ? nil : config.password,
                    privateKeyPath: config.privateKeyPath.isEmpty ? nil : config.privateKeyPath,
                    remoteHost: remoteHost,
                    remotePort: remotePort,
                    mode: config.mode
                )
            }
            return tunnel
        } catch {
            tunnel.stop()
            throw error
        }
    }
}
