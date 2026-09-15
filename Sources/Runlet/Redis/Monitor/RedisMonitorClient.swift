import Foundation
import Network
import Synchronization

final class RedisMonitorClient: Sendable {
    private final class ConnectContinuationState: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<Void, Error>?
            var result: Result<Void, Error>?
        }

        private let state = Mutex(State())

        var isCompleted: Bool {
            state.withLock { $0.result != nil }
        }

        func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            let result = state.withLock { state -> Result<Void, Error>? in
                if let result = state.result {
                    return result
                }
                state.continuation = continuation
                return nil
            }

            if let result {
                resume(continuation, with: result)
            }
        }

        @discardableResult
        func complete(_ result: Result<Void, Error>) -> Bool {
            let (continuation, didComplete) = state.withLock { state -> (CheckedContinuation<Void, Error>?, Bool) in
                guard state.result == nil else { return (nil, false) }
                state.result = result
                let continuation = state.continuation
                state.continuation = nil
                return (continuation, true)
            }

            if let continuation {
                resume(continuation, with: result)
            }
            return didComplete
        }

        private func resume(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private final class PendingCommand: Sendable {
        private let continuation = Mutex<CheckedContinuation<RESPValue, Error>?>(nil)

        init(_ continuation: CheckedContinuation<RESPValue, Error>) {
            self.continuation.withLock { $0 = continuation }
        }

        func complete(_ result: Result<RESPValue, Error>) {
            let continuation = self.continuation.withLock { state -> CheckedContinuation<RESPValue, Error>? in
                let continuation = state
                state = nil
                return continuation
            }

            guard let continuation else { return }

            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private struct State: Sendable {
        var connection: NWConnection?
        var pendingCompletions: [PendingCommand] = []
        var parser = RESPParser()
        var isConnected = false
        var isMonitoring = false
        var monitorContinuation: AsyncThrowingStream<String, Error>.Continuation?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "redis.monitor.client.queue")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let tlsValidationQueue = DispatchQueue(label: "redis.monitor.tls-validation")

    private let host: String
    private let port: UInt16
    private let username: String?
    private let password: String?
    private let tlsEnabled: Bool
    private let verifyServerCertificate: Bool
    private let caCertificatePath: String
    private let clientCertificatePath: String
    private let clientKeyPath: String
    private let connectionTimeout: TimeInterval

    /// Client TLS identity (certificate + private key). Retained for the
    /// connection's lifetime and released on disconnect; its temporary keychain
    /// must stay alive so the `sec_identity_t` keeps referencing the key.
    private let clientIdentityBundle = Mutex<LoadedClientIdentity?>(nil)

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
        connectionTimeout: TimeInterval = 10
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
        self.connectionTimeout = connectionTimeout
        queue.setSpecific(key: queueKey, value: true)
    }

    func startMonitoring() async throws -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(
            of: String.self,
            throwing: Error.self,
            bufferingPolicy: .bufferingNewest(2_000)
        )

        state.withLock { $0.monitorContinuation = continuation }

        continuation.onTermination = { [weak self] _ in
            self?.disconnect()
        }

        do {
            try await withTimeout(connectionTimeout, context: "Redis MONITOR connection") {
                try await self.connect()
            }
            try await authenticateIfNeeded()
            state.withLock { $0.isMonitoring = true }

            let result = try await send("MONITOR")
            guard case .simpleString(let message) = result, message.uppercased() == "OK" else {
                if case .error(let message) = result {
                    throw RedisError.commandError(message)
                }
                throw RedisError.commandError("Unexpected MONITOR response: \(result.displayString)")
            }

            return stream
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        runOnQueue {
            self.cancelConnectionOnQueue(finishError: nil)
            self.clearClientIdentity()
        }
    }

    /// Deletes the temporary keychain backing the client TLS identity (if any)
    /// and drops the retained bundle so the private key is no longer kept alive.
    private func clearClientIdentity() {
        if let keychain = clientIdentityBundle.withLock({ $0?.keychain }) {
            SecKeychainDelete(keychain)
        }
        clientIdentityBundle.withLock { $0 = nil }
    }

    private func connect() async throws {
        let connectContinuation = ConnectContinuationState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectContinuation.setContinuation(continuation)

                var localIdentity: sec_identity_t?
                if clientCertificatePath.isEmpty != clientKeyPath.isEmpty {
                    connectContinuation.complete(.failure(ClientIdentityLoaderError.incompleteConfiguration))
                    return
                } else if !clientCertificatePath.isEmpty {
                    do {
                        clearClientIdentity()
                        guard
                            let bundle = try loadClientIdentity(
                                certificatePath: clientCertificatePath,
                                keyPath: clientKeyPath
                            )
                        else {
                            connectContinuation.complete(.failure(ClientIdentityLoaderError.incompleteConfiguration))
                            return
                        }
                        self.clientIdentityBundle.withLock { $0 = bundle }
                        localIdentity = bundle.secIdentity
                    } catch {
                        connectContinuation.complete(.failure(error))
                        return
                    }
                }

                let params = makeConnectionParameters(localIdentity: localIdentity)

                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    connectContinuation.complete(.failure(RedisError.commandError("Invalid Redis port: \(port)")))
                    return
                }

                let connection = NWConnection(
                    host: NWEndpoint.Host(host),
                    port: nwPort,
                    using: params
                )
                state.withLock { $0.connection = connection }

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }

                    switch state {
                    case .ready:
                        guard !connectContinuation.isCompleted else { return }
                        self.state.withLock { $0.isConnected = true }
                        self.receiveLoop()
                        connectContinuation.complete(.success(()))
                    case .failed(let error):
                        self.state.withLock { $0.isConnected = false }
                        self.completePendingCommands(with: error)
                        self.finishMonitor(with: error)
                        connectContinuation.complete(.failure(error))
                    case .cancelled:
                        self.state.withLock { $0.isConnected = false }
                        connectContinuation.complete(.failure(RedisError.notConnected))
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
            }
        } onCancel: {
            connectContinuation.complete(.failure(CancellationError()))
            self.cancelConnectionForCancellation()
        }
    }

    private func makeConnectionParameters(localIdentity: sec_identity_t?) -> NWParameters {
        guard tlsEnabled else {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            return params
        }

        let tlsOptions = NWProtocolTLS.Options()

        if !caCertificatePath.isEmpty || !clientCertificatePath.isEmpty || !clientKeyPath.isEmpty {
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { [caCertificatePath] _, trust, completionHandler in
                    // swiftlint:disable:next force_cast
                    let secTrust = trust as! SecTrust

                    if !caCertificatePath.isEmpty {
                        let url = URL(fileURLWithPath: caCertificatePath)
                        if let caData = try? Data(contentsOf: url) {
                            let caCert = SecCertificateCreateWithData(nil, caData as CFData)
                            if let caCert {
                                SecTrustSetAnchorCertificates(secTrust, [caCert] as CFArray)
                                SecTrustSetAnchorCertificatesOnly(secTrust, false)
                            }
                        }
                    }

                    var error: CFError?
                    let isValid = SecTrustEvaluateWithError(secTrust, &error)
                    completionHandler(isValid)
                },
                tlsValidationQueue
            )
        } else if !verifyServerCertificate {
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, _, completionHandler in
                    completionHandler(true)
                },
                tlsValidationQueue
            )
        }

        if let localIdentity {
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                localIdentity
            )
        }

        sec_protocol_options_set_tls_server_name(
            tlsOptions.securityProtocolOptions,
            host
        )

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        params.allowLocalEndpointReuse = true
        return params
    }

    private func authenticateIfNeeded() async throws {
        let user = username ?? ""
        let pw = password ?? ""
        guard !user.isEmpty || !pw.isEmpty else { return }

        let result: RESPValue
        if user.isEmpty {
            result = try await send("AUTH", pw)
        } else {
            result = try await send("AUTH", user, pw)
        }

        if case .error(let message) = result {
            throw RedisError.commandError(message)
        }
    }

    private func receiveLoop() {
        queue.async {
            self.receiveOnQueue()
        }
    }

    private func receiveOnQueue() {
        let connection = state.withLock { $0.connection }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            self?.handleReceive(data: data, isComplete: isComplete, error: error)
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            queue.async {
                self.state.withLock { $0.parser.append(data) }
                self.processBuffer()
            }
        }

        if error == nil && !isComplete {
            receiveLoop()
        } else {
            queue.async {
                let finishError: Error = error ?? RedisError.notConnected
                self.completePendingCommands(with: finishError)
                self.state.withLock {
                    $0.parser = RESPParser()
                    $0.isConnected = false
                }
                self.finishMonitor(with: finishError)
            }
        }
    }

    private func processBuffer() {
        let (completions, monitorLines, finishError) = state.withLock {
            var completions: [(PendingCommand, RESPValue)] = []
            var monitorLines: [String] = []
            var finishError: RedisError?

            do {
                while let message = try $0.parser.parse() {
                    let value: RESPValue
                    switch message {
                    case .response(let parsedValue), .push(let parsedValue):
                        value = parsedValue
                    }
                    if let completion = $0.pendingCompletions.first {
                        $0.pendingCompletions.removeFirst()
                        completions.append((completion, value))
                    } else if $0.isMonitoring, let line = value.string {
                        monitorLines.append(line)
                    } else if case .error(let message) = value {
                        finishError = RedisError.commandError(message)
                    }
                }
                $0.parser.compact()
            } catch {
                // Desynchronized stream: complete everything and tear down.
                let pending = $0.pendingCompletions
                $0.pendingCompletions.removeAll()
                $0.parser = RESPParser()
                $0.isConnected = false
                for completion in pending {
                    completion.complete(.failure(RedisError.commandError("RESP protocol error: \(error.localizedDescription)")))
                }
                finishError = RedisError.commandError("RESP protocol error: \(error.localizedDescription)")
            }
            return (completions, monitorLines, finishError)
        }

        for (completion, value) in completions {
            completion.complete(.success(value))
        }
        if !monitorLines.isEmpty {
            let continuation = state.withLock { $0.monitorContinuation }
            for line in monitorLines {
                continuation?.yield(line)
            }
        }
        if let finishError {
            finishMonitor(with: finishError)
        }
    }

    private func send(_ args: String...) async throws -> RESPValue {
        try await send(args)
    }

    private func send(_ args: [String]) async throws -> RESPValue {
        let data = RESPEncoder.encode(args)
        // A box is needed because the cancellation hook is a separate `@Sendable`
        // closure and cannot capture the locally-scoped `PendingCommand` directly.
        let pendingBox = Mutex<PendingCommand?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pendingCompletion = PendingCommand(continuation)
                pendingBox.withLock { $0 = pendingCompletion }

                self.queue.async {
                    guard let connection = self.state.withLock({ $0.connection }),
                        self.state.withLock({ $0.isConnected })
                    else {
                        pendingCompletion.complete(.failure(RedisError.notConnected))
                        return
                    }

                    self.state.withLock { $0.pendingCompletions.append(pendingCompletion) }

                    connection.send(
                        content: data,
                        completion: .contentProcessed { error in
                            if let error {
                                self.queue.async {
                                    self.failPendingCompletion(pendingCompletion, with: error)
                                }
                            }
                        })
                }
            }
        } onCancel: {
            // Without this hook a half-open connection whose `connection.send`
            // completion never arrives would leave the continuation suspended
            // forever, so the enclosing task group (e.g. withTimeout) can never
            // join the cancelled child and the call hangs indefinitely.
            if let pendingCompletion = pendingBox.withLock({ $0 }) {
                self.removePendingCompletion(pendingCompletion)
                pendingCompletion.complete(.failure(CancellationError()))
            }
        }
    }

    private func removePendingCompletion(_ completion: PendingCommand) {
        state.withLock {
            if let index = $0.pendingCompletions.firstIndex(where: { $0 === completion }) {
                $0.pendingCompletions.remove(at: index)
            }
        }
    }

    private func failPendingCompletion(_ completion: PendingCommand, with error: Error) {
        removePendingCompletion(completion)
        completion.complete(.failure(error))
    }

    private func completePendingCommands(with error: Error) {
        let pendingCompletions = state.withLock {
            let pendingCompletions = $0.pendingCompletions
            $0.pendingCompletions.removeAll()
            return pendingCompletions
        }
        for completion in pendingCompletions {
            completion.complete(.failure(error))
        }
    }

    private func cancelConnectionOnQueue(finishError: Error?) {
        let connection = state.withLock {
            let connection = $0.connection
            $0.connection = nil
            $0.isConnected = false
            $0.isMonitoring = false
            $0.parser = RESPParser()
            return connection
        }
        connection?.cancel()
        completePendingCommands(with: finishError ?? RedisError.notConnected)
        finishMonitor(with: finishError)
    }

    private func cancelConnectionForCancellation() {
        let cancelAction: @Sendable () -> Void = {
            self.cancelConnectionOnQueue(finishError: CancellationError())
        }

        if DispatchQueue.getSpecific(key: queueKey) == true {
            cancelAction()
        } else {
            queue.async(execute: cancelAction)
        }
    }

    private func finishMonitor(with error: Error?) {
        let continuation = state.withLock {
            let continuation = $0.monitorContinuation
            $0.monitorContinuation = nil
            $0.isMonitoring = false
            return continuation
        }

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    private func runOnQueue(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            action()
        } else {
            queue.sync(execute: action)
        }
    }

    deinit {
        disconnect()
    }
}
