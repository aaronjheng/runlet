import Foundation

/// Multiplexed system-`ssh` connection pool (external SSH mode).
///
/// This mirrors the approach Sequel-Ace takes with its bundled OpenSSH
/// client — drive the local `ssh(1)` binary instead of reimplementing the
/// protocol — with connection reuse built in: tunnels to the same SSH
/// destination share a single multiplexed master connection
/// (`ControlMaster`), and each Redis tunnel is only a lightweight
/// `-O forward` port forwarding on that master. A cluster with six nodes
/// therefore costs one SSH handshake instead of six, and agent identities,
/// `~/.ssh/config` (ProxyJump, IdentityFile, …), `known_hosts` and
/// certificates behave exactly like in Terminal.
///
/// Key reuse properties:
/// - The pool is keyed by `(host, port, user, identity)`. Main connection,
///   shell, profiler and every cluster node tunnel to the same destination
///   share one master automatically, across the whole app (shared instance).
/// - Teardown is reference counted: closing one tunnel only cancels its own
///   forwarding. The master is exited (`-O exit`) when the last lease ends,
///   so teardown order can never kill unrelated tunnels.
/// - An explicit long-lived master (rather than `ControlMaster=auto` on
///   every tunnel) is used precisely so that stopping any single tunnel is
///   always safe, no matter which tunnel started first.
actor SystemSSHConnectionPool {
    static let shared = SystemSSHConnectionPool()

    /// Handle for one port forwarding on a shared master connection.
    struct Lease: Sendable, Hashable {
        let key: Key
        let connectionID: UUID
        let localPort: UInt16
        /// The exact `-L` spec registered on the master; reused for `-O cancel`.
        let forwardingSpec: String
    }

    struct Key: Sendable, Hashable {
        let host: String
        let port: UInt16
        let user: String
        let keyPath: String

        init(host: String, port: UInt16, user: String, keyPath: String?) {
            self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            self.port = port
            self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
            self.keyPath = (keyPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct SharedConnection {
        let id = UUID()
        var process: Process
        var controlPath: String
        var destination: String
        var logPath: String
        /// Retained for the master's lifetime: releasing it early closes the
        /// fd before spawn and silently swallows all of ssh's stderr.
        var errorHandle: FileHandle?
        var ready: Bool
        var refcount: Int
    }

    static let sshBinaryPath = "/usr/bin/ssh"

    /// Idle-master grace period (seconds). Only matters for orphaned master
    /// processes left behind by a crash: they exit on their own instead of
    /// lingering. Normal teardown uses `-O exit` when the last lease closes.
    private static let controlPersistSeconds = 600

    private var connections: [Key: SharedConnection] = [:]

    /// Private directory for control sockets, created once per process.
    /// Unix domain socket paths are limited to ~104 bytes and macOS
    /// per-user temp dirs alone already eat ~50 of them, so sockets live in
    /// a short `mkdtemp` dir under `/tmp` (e.g. `/tmp/runlet-ssh-aB3x9Q/3f96365b5a12.sock`,
    /// ~49 bytes) instead of `FileManager.temporaryDirectory`.
    private var socketDir: String?
    private var didSweepStaleSocketDirs = false

    // MARK: - Forwardings

    /// Opens `127.0.0.1:<localPort> -> remoteHost:remotePort` through the
    /// shared master for `key`, starting the master first if needed.
    func openForwarding(
        key: Key,
        remoteHost: String,
        remotePort: UInt16,
        setupTimeout: TimeInterval
    ) async throws -> Lease {
        guard !key.host.isEmpty else {
            throw SSHTunnelError.connectionFailed("SSH host is required")
        }
        guard FileManager.default.isExecutableFile(atPath: Self.sshBinaryPath) else {
            throw SSHTunnelError.connectionFailed("System ssh not found at \(Self.sshBinaryPath)")
        }

        let localPort = findAvailablePort()
        let spec = "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"
        let deadline = Date().addingTimeInterval(max(1, setupTimeout))

        do {
            // Wait for a ready master, launching one when no entry exists.
            // The entry may vanish underneath us (a concurrent failure tore
            // down an unused master); loop back and relaunch in that case.
            var connectionID = UUID()
            while true {
                try Task.checkCancellation()
                if connections[key] == nil {
                    try await launchSharedConnection(key: key, setupTimeout: setupTimeout)
                }
                if try await waitUntilConnectionReady(key: key, deadline: deadline) {
                    connectionID = connections[key]?.id ?? connectionID
                    break
                }
            }

            guard let entry = connections[key], entry.id == connectionID else {
                throw SSHTunnelError.connectionFailed("System ssh master vanished while opening \(spec)")
            }

            do {
                let result = try await runControlCommand(
                    ["-S", entry.controlPath, "-O", "forward", "-L", spec, entry.destination],
                    timeoutSeconds: 15
                )
                guard result.status == 0 else {
                    throw SSHTunnelError.connectionFailed(
                        "System ssh port forwarding failed (\(spec)): \(redactedTail(result.errorOutput))"
                    )
                }
            } catch {
                teardownConnectionIfUnused(key: key)
                throw error
            }

            do {
                try await waitUntilLocalPortOpen(localPort, deadline: deadline)
            } catch {
                await cancelForwardingBestEffort(entry: entry, spec: spec)
                teardownConnectionIfUnused(key: key)
                throw error
            }

            guard connections[key]?.id == connectionID else {
                throw SSHTunnelError.connectionFailed("System ssh master changed while opening \(spec)")
            }
            connections[key]?.refcount += 1
            let reused = (connections[key]?.refcount ?? 1) > 1
            AppLogger.info(
                "system ssh forwarding ready \(reused ? "reused master" : "new master") "
                    + "ssh=\(key.host):\(key.port) local=127.0.0.1:\(localPort) remote=\(remoteHost):\(remotePort)",
                category: "SSHTunnel"
            )
            return Lease(key: key, connectionID: connectionID, localPort: localPort, forwardingSpec: spec)
        } catch {
            if error is CancellationError {
                teardownConnectionIfUnused(key: key)
            }
            throw error
        }
    }

    /// Cancels one forwarding and releases its master reference. The master
    /// itself is exited only when the last lease ends.
    func close(_ lease: Lease) async {
        guard var entry = connections[lease.key], entry.id == lease.connectionID else {
            AppLogger.info(
                "system ssh forwarding already gone local=127.0.0.1:\(lease.localPort)",
                category: "SSHTunnel"
            )
            return
        }

        await cancelForwardingBestEffort(entry: entry, spec: lease.forwardingSpec)
        entry.refcount = max(0, entry.refcount - 1)

        guard entry.refcount == 0 else {
            connections[lease.key] = entry
            AppLogger.info(
                "system ssh forwarding closed local=127.0.0.1:\(lease.localPort) "
                    + "master retained (\(entry.refcount) user(s))",
                category: "SSHTunnel"
            )
            return
        }

        connections.removeValue(forKey: lease.key)
        _ = try? await runControlCommand(["-S", entry.controlPath, "-O", "exit", entry.destination], timeoutSeconds: 5)
        if entry.process.isRunning {
            entry.process.terminate()
        }
        try? entry.errorHandle?.close()
        try? FileManager.default.removeItem(atPath: entry.logPath)
        AppLogger.info("system ssh master stopped ssh=\(lease.key.host):\(lease.key.port)", category: "SSHTunnel")
    }

    // MARK: - Master lifecycle

    private func launchSharedConnection(key: Key, setupTimeout: TimeInterval) async throws {
        let destination = key.user.isEmpty ? key.host : "\(key.user)@\(key.host)"
        let paths = try await controlPaths(key: key)
        let controlPath = paths.socket
        let logPath = paths.log

        // Minimal overrides so the local SSH infrastructure stays in charge:
        // user, port and identity resolve from ~/.ssh/config unless the
        // connection form sets them explicitly. Password/passphrase prompts
        // are disabled (BatchMode): external mode authenticates with keys,
        // certificates and ssh-agent only.
        var args = [
            "-M", "-N",
            "-S", controlPath,
            "-o", "ControlPersist=\(Self.controlPersistSeconds)",
            "-o", "BatchMode=yes",
            // Never fork away even if the user's config sets
            // ForkAfterAuthentication (common for jump/tunnel hosts): the
            // pool tracks the foreground process, and a forked-away parent
            // exits 0, which looks exactly like a silent instant death.
            "-o", "ForkAfterAuthentication=no",
            // ConnectTimeout arms both the TCP connect and the banner
            // exchange. With stdio proxies (ProxyJump, `tsh proxy ssh`) the
            // TCP leg opens instantly, then the proxy may run an interactive
            // flow (browser login) before the banner arrives — so the value
            // must cover the whole setup budget instead of a short fixed
            // constant. The pool-level deadline matches `setupTimeout` too.
            "-o", "ConnectTimeout=\(Int(max(1, setupTimeout)))",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes",
            // Accept unseen host keys into known_hosts (like answering "yes"
            // in Terminal) while still rejecting changed keys. Strictly safer
            // than the built-in mode, which accepts every key every time.
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        if key.port != 22 {
            args += ["-p", "\(key.port)"]
        }
        if !key.keyPath.isEmpty {
            args += ["-i", (key.keyPath as NSString).expandingTildeInPath]
        }
        args.append(destination)

        _ = FileManager.default.createFile(atPath: logPath, contents: nil)
        let process = Process()
        process.executableURL = URL(filePath: Self.sshBinaryPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorHandle = try? FileHandle(forWritingTo: URL(filePath: logPath))
        process.standardError = errorHandle

        // Publish the entry before spawning so concurrent openers wait on it
        // instead of launching a second master for the same key.
        connections[key] = SharedConnection(
            process: process,
            controlPath: controlPath,
            destination: destination,
            logPath: logPath,
            errorHandle: errorHandle,
            ready: false,
            refcount: 0
        )
        do {
            try process.run()
        } catch {
            closeLogHandle(for: key)
            connections.removeValue(forKey: key)
            throw SSHTunnelError.connectionFailed("Failed to launch system ssh: \(error.localizedDescription)")
        }
        let agentState = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] == nil ? "unset" : "set"
        AppLogger.info(
            "system ssh master starting ssh=\(key.host):\(key.port) user=\(key.user.isEmpty ? "(from ssh config)" : key.user) "
                + "socket=\(controlPath) agent=\(agentState)",
            category: "SSHTunnel"
        )
    }

    /// Returns true once the master's entry is ready. Returns false when the
    /// entry vanished (caller relaunches). Throws when the master died or the
    /// deadline passed.
    private func waitUntilConnectionReady(key: Key, deadline: Date) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            guard let entry = connections[key] else { return false }
            if entry.ready { return true }
            if !entry.process.isRunning {
                // A parent that forked to background anyway exits 0 while its
                // child keeps serving the socket: adopt it instead of
                // reporting a silent death.
                if entry.process.terminationStatus == 0 {
                    let adopted = try? await runControlCommand(
                        ["-S", entry.controlPath, "-O", "check", entry.destination],
                        timeoutSeconds: 5
                    )
                    if adopted?.status == 0 {
                        connections[key]?.ready = true
                        AppLogger.info(
                            "system ssh master adopted backgrounded process ssh=\(key.host):\(key.port)",
                            category: "SSHTunnel"
                        )
                        return true
                    }
                }
                let tail = readLogTail(entry.logPath)
                let status = entry.process.terminationStatus
                if entry.refcount == 0 {
                    closeLogHandle(for: key)
                    connections.removeValue(forKey: key)
                }
                throw SSHTunnelError.connectionFailed(connectionFailureMessage(key: key, status: status, tail: tail))
            }
            if Date() > deadline {
                if entry.refcount == 0 {
                    entry.process.terminate()
                    closeLogHandle(for: key)
                    connections.removeValue(forKey: key)
                }
                throw SSHTunnelError.connectionFailed("System ssh connection timed out for \(key.host):\(key.port)")
            }
            // `-O check` fails until the master accepts multiplex commands.
            let check = try? await runControlCommand(
                ["-S", entry.controlPath, "-O", "check", entry.destination],
                timeoutSeconds: 5
            )
            if check?.status == 0 {
                connections[key]?.ready = true
                AppLogger.info("system ssh master ready ssh=\(key.host):\(key.port)", category: "SSHTunnel")
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitUntilLocalPortOpen(_ port: UInt16, deadline: Date) async throws {
        while true {
            try Task.checkCancellation()
            if isLocalPortOpen(port) { return }
            if Date() > deadline {
                throw SSHTunnelError.connectionFailed("System ssh forwarding did not come up on 127.0.0.1:\(port)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Removes a master entry only when nothing uses it. Concurrent openers
    /// waiting on the entry observe the removal and relaunch.
    private func teardownConnectionIfUnused(key: Key) {
        guard let entry = connections[key], entry.refcount == 0 else { return }
        if entry.process.isRunning {
            entry.process.terminate()
        }
        closeLogHandle(for: key)
        connections.removeValue(forKey: key)
        try? FileManager.default.removeItem(atPath: entry.logPath)
    }

    /// Closes the retained stderr handle before its entry is dropped.
    private func closeLogHandle(for key: Key) {
        try? connections[key]?.errorHandle?.close()
        connections[key]?.errorHandle = nil
    }

    /// Terminates every master and removes the process-private socket dir, so
    /// no socket or log files are left in `/tmp` on quit. Crash or `kill -9`
    /// exits skip this and still rely on the next launch's sweep.
    func shutdownAll() {
        for key in Array(connections.keys) {
            if let entry = connections[key], entry.process.isRunning {
                entry.process.terminate()
            }
            closeLogHandle(for: key)
            connections.removeValue(forKey: key)
        }
        if let socketDir {
            try? FileManager.default.removeItem(atPath: socketDir)
            self.socketDir = nil
        }
        AppLogger.info("system ssh pool shut down", category: "SSHTunnel")
    }

    private func connectionFailureMessage(key: Key, status: Int32, tail: String) -> String {
        var message =
            "System ssh connection failed (exit \(status)). It uses your keys, certificates and ssh-agent "
            + "with ~/.ssh/config (ProxyJump supported); the configured password is ignored. "
        if tail.isEmpty {
            let agentState = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] == nil ? "not set" : "set"
            message +=
                "ssh exited without output. If `ssh \(key.host)` works in Terminal, compare environments: "
                + "GUI apps do not inherit shell-only setup, e.g. ssh-agent (SSH_AUTH_SOCK is \(agentState) here). "
                + "Also check ~/.ssh/config for options that need an interactive session."
        } else {
            message += "ssh: \(tail)"
        }
        return message
    }

    private func cancelForwardingBestEffort(entry: SharedConnection, spec: String) async {
        let result = try? await runControlCommand(
            ["-S", entry.controlPath, "-O", "cancel", "-L", spec, entry.destination],
            timeoutSeconds: 5
        )
        if result?.status != 0, let output = result?.errorOutput, !redactedTail(output).isEmpty {
            AppLogger.warn("system ssh cancel forwarding notice: \(redactedTail(output))", category: "SSHTunnel")
        }
    }

    // MARK: - Control socket paths

    /// Returns the control socket + stderr log paths for `key` inside the
    /// process-private socket dir. A leftover socket can only belong to a
    /// dead master (the pool holds no live entry for it when this runs), so
    /// unlinking before rebind is safe.
    private func controlPaths(key: Key) async throws -> (socket: String, log: String) {
        let dir = try await ensureSocketDir()
        // Fingerprint of the SSH destination (`user@host:port#keyPath`), so
        // each destination gets its own socket/log pair in the shared dir.
        let fingerprint = String(stableHash("\(key.user)@\(key.host):\(key.port)#\(key.keyPath)").prefix(12))
        let socket = "\(dir)/\(fingerprint).sock"
        if FileManager.default.fileExists(atPath: socket) {
            AppLogger.debug("system ssh removing leftover control socket \(socket)", category: "SSHTunnel")
            try? FileManager.default.removeItem(atPath: socket)
        }
        let log = "\(dir)/\(fingerprint).log"
        return (socket, log)
    }

    private func ensureSocketDir() async throws -> String {
        if let socketDir { return socketDir }
        await sweepStaleSocketDirsIfNeeded()
        let dir = try makePrivateSocketDir()
        socketDir = dir
        return dir
    }

    /// Creates an unguessable 0700 directory for control sockets. The random
    /// component prevents other local users from squatting predictable socket
    /// paths in the shared `/tmp`.
    private func makePrivateSocketDir() throws -> String {
        var template = Array("/tmp/runlet-ssh-XXXXXXXX".utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(validatingCString: base)
        }
        guard let created else {
            throw SSHTunnelError.connectionFailed("Could not create a private socket directory for system ssh")
        }
        return created
    }

    /// Removes socket dirs from previous runs (crash orphans) that hold no
    /// live master. Only directories owned by the current user are touched;
    /// a master that still answers `-O check` (e.g. another app instance) is
    /// left alone.
    private func sweepStaleSocketDirsIfNeeded() async {
        guard !didSweepStaleSocketDirs else { return }
        didSweepStaleSocketDirs = true
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") else { return }
        let uid = getuid()
        for name in names where name.hasPrefix("runlet-ssh-") {
            let dir = "/tmp/\(name)"
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: dir),
                (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == uid
            else { continue }
            let socket = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .first(where: { !$0.hasSuffix(".log") })
                .map { "\(dir)/\($0)" }
            if let socket {
                let probe = try? await runControlCommand(["-S", socket, "-O", "check", "localhost"], timeoutSeconds: 5)
                if probe?.status == 0 { continue }
            }
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    private func stableHash(_ value: String) -> String {
        // FNV-1a 64-bit: stable across launches, no extra dependency.
        var hash: UInt64 = 14_695_981_039_665_703_737
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Process plumbing

    private struct ControlResult {
        let status: Int32
        let output: String
        let errorOutput: String
    }

    /// Runs a short-lived multiplex control command (`-O check/forward/
    /// cancel/exit`). These complete in milliseconds; a watchdog terminates
    /// a hung invocation so a dead master can never block the pool.
    ///
    /// `Process.waitUntilExit()` blocks its thread, so the blocking wait hops
    /// to a detached task (global pool) instead of stalling this actor's
    /// executor behind every other pooled tunnel.
    private func runControlCommand(_ args: [String], timeoutSeconds: TimeInterval) async throws -> ControlResult {
        try await Task.detached {
            try Self.runControlCommandBlocking(args, timeoutSeconds: timeoutSeconds)
        }.value
    }

    private nonisolated static func runControlCommandBlocking(
        _ args: [String],
        timeoutSeconds: TimeInterval
    ) throws -> ControlResult {
        let process = Process()
        process.executableURL = URL(filePath: Self.sshBinaryPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw SSHTunnelError.connectionFailed("Failed to launch system ssh: \(error.localizedDescription)")
        }

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(Int64(max(1, timeoutSeconds))))
            if process.isRunning {
                process.terminate()
            }
        }
        process.waitUntilExit()
        watchdog.cancel()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ControlResult(status: process.terminationStatus, output: output, errorOutput: errorOutput)
    }

    private func readLogTail(_ path: String, maxBytes: Int = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(filePath: path)) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.readToEnd()) ?? Data()
        return redactedTail(String(data: data.suffix(maxBytes), encoding: .utf8) ?? "")
    }

    /// Trims ssh diagnostics for display. External mode never sends secrets
    /// to ssh (BatchMode, no password), so this is formatting only.
    private func redactedTail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Local ports

    private func findAvailablePort() -> UInt16 {
        // Ask the OS for a free port by binding an ephemeral listener, then
        // close it. This avoids both the check-then-use race of scanning
        // random candidates and the unvalidated fallback port.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return UInt16.random(in: 10000..<60000) }
        defer { Darwin.close(sock) }

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
        defer { Darwin.close(sock) }

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

    private func isLocalPortOpen(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // 127.0.0.1 in network byte order.
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
