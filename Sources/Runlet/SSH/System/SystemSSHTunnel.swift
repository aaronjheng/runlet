import Foundation
import Synchronization

/// System-`ssh` tunnel (external SSH mode).
///
/// A thin facade over `SystemSSHConnectionPool`: each instance owns one
/// `-O forward` lease on a shared multiplexed master connection, so the
/// interface mirrors `SSHTunnel` and every call site (connect, test,
/// shell, profiler, cluster) treats both modes uniformly.
///
/// Authentication always comes from the local SSH infrastructure — agent
/// identities, certificates, `~/.ssh/config` (including ProxyJump) and
/// `known_hosts`. A configured password is ignored by design (see
/// `SystemSSHConnectionPool`): use `ssh-agent` for key passphrases.
final class SystemSSHTunnel: @unchecked Sendable {
    var setupTimeoutSeconds: TimeInterval = 30

    private struct State {
        var lease: SystemSSHConnectionPool.Lease?
        var localPort: UInt16 = 0
        var isRunning = false
    }

    private let state = Mutex(State())

    private(set) var localPort: UInt16 {
        get { state.withLock { $0.localPort } }
        set { state.withLock { $0.localPort = newValue } }
    }

    private(set) var isRunning: Bool {
        get { state.withLock { $0.isRunning } }
        set { state.withLock { $0.isRunning = newValue } }
    }

    // swiftlint:disable:next function_parameter_count
    func start(
        sshHost: String,
        sshPort: UInt16,
        sshUser: String,
        sshPassword: String? = nil,
        privateKeyPath: String?,
        remoteHost: String,
        remotePort: UInt16
    ) async throws {
        if let password = sshPassword, !password.isEmpty {
            AppLogger.warn(
                "system ssh ignores the configured password; using keys/certificates, ssh-agent and ~/.ssh/config",
                category: "SSHTunnel"
            )
        }
        let effectiveUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.info(
            "start requested mode=systemSSH ssh=\(sshHost):\(sshPort) user=\(effectiveUser.isEmpty ? "(from ssh config)" : effectiveUser) "
                + "remote=\(remoteHost):\(remotePort)",
            category: "SSHTunnel"
        )

        let lease = try await SystemSSHConnectionPool.shared.openForwarding(
            key: SystemSSHConnectionPool.Key(host: sshHost, port: sshPort, user: sshUser, keyPath: privateKeyPath),
            remoteHost: remoteHost,
            remotePort: remotePort,
            setupTimeout: setupTimeoutSeconds
        )
        state.withLock {
            $0.lease = lease
            $0.localPort = lease.localPort
            $0.isRunning = true
        }
        AppLogger.info("tunnel mode=systemSSH ready local=127.0.0.1:\(lease.localPort)", category: "SSHTunnel")
    }

    func stop() {
        let lease = state.withLock { (state: inout State) -> SystemSSHConnectionPool.Lease? in
            state.isRunning = false
            let taken = state.lease
            state.lease = nil
            return taken
        }
        guard let lease else { return }
        AppLogger.info("stop tunnel mode=systemSSH local=127.0.0.1:\(lease.localPort)", category: "SSHTunnel")
        // `close()` only runs fast multiplex control commands, but it is an
        // actor call, so release asynchronously like the NIO group shutdown.
        Task {
            await SystemSSHConnectionPool.shared.close(lease)
        }
    }

    deinit {
        stop()
    }
}
