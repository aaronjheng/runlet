import Foundation
import Network

// MARK: - Connect / Disconnect

/// Connection lifecycle for `RedisClient`: NWConnection setup with TLS and
/// client identity, the connect-time AUTH/RESP3 handshake, and teardown.
extension RedisClient {
    func connect() async throws {
        try await withTimeout(connectionTimeout, context: "Redis connection") {
            try await self.performConnect()
        }
    }

    private func performConnect() async throws {
        try Task.checkCancellation()
        let connectContinuation = ConnectContinuationState()
        // A repeated connect() must not leak the previous connection.
        let staleConnection = state.withLock { $0.connection }
        staleConnection?.cancel()
        let staleCompletions = state.withLock {
            let pendingCompletions = $0.pendingCompletions.compactMap(\.command)
            $0.isConnected = false
            $0.lastError = nil
            $0.pendingCompletions.removeAll()
            $0.parser = RESPParser()
            $0.negotiatedProtocolVersion = .resp2
            $0.serverCapabilities = [:]
            $0.protocolFallbackReason = nil
            return pendingCompletions
        }
        for completion in staleCompletions {
            completion.complete(.failure(RedisError.notConnected))
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectContinuation.setContinuation(continuation)
                guard !connectContinuation.isCompleted else { return }
                guard !Task.isCancelled else {
                    connectContinuation.complete(.failure(CancellationError()))
                    return
                }

                let params: NWParameters
                if tlsEnabled {
                    let tlsOptions = NWProtocolTLS.Options()

                    if !caCertificatePath.isEmpty || !clientCertificatePath.isEmpty || !clientKeyPath.isEmpty {
                        sec_protocol_options_set_verify_block(
                            tlsOptions.securityProtocolOptions,
                            { [caCertificatePath = self.caCertificatePath] _, trust, completionHandler in
                                // swiftlint:disable:next force_cast
                                let secTrust = trust as! SecTrust

                                if !caCertificatePath.isEmpty {
                                    let url = URL(fileURLWithPath: caCertificatePath)
                                    guard let caData = try? Data(contentsOf: url),
                                        let caCert = SecCertificateCreateWithData(nil, caData as CFData)
                                    else {
                                        // The configured CA cannot be read: fail the
                                        // connection rather than fall back to the
                                        // system trust store without telling anyone.
                                        completionHandler(false)
                                        return
                                    }
                                    SecTrustSetAnchorCertificates(secTrust, [caCert] as CFArray)
                                    SecTrustSetAnchorCertificatesOnly(secTrust, false)
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
                            sec_protocol_options_set_local_identity(
                                tlsOptions.securityProtocolOptions,
                                bundle.secIdentity
                            )
                        } catch {
                            connectContinuation.complete(.failure(error))
                            return
                        }
                    }

                    sec_protocol_options_set_tls_server_name(
                        tlsOptions.securityProtocolOptions,
                        host
                    )

                    params = NWParameters(tls: tlsOptions, tcp: .init())
                } else {
                    params = NWParameters.tcp
                }
                params.allowLocalEndpointReuse = true
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    connectContinuation.complete(.failure(RedisError.commandError("Invalid Redis port: \(port)")))
                    return
                }

                let connection = NWConnection(
                    host: NWEndpoint.Host(host),
                    port: nwPort,
                    using: params
                )
                state.withLock {
                    $0.connection = connection
                }
                guard !connectContinuation.isCompleted else {
                    cancelConnectionForCancellation()
                    return
                }

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard !connectContinuation.isCompleted else { return }
                        self.updateConnectionState(isConnected: true)
                        self.startReceiving()

                        let handshakeTask = Task {
                            defer { self.state.withLock { $0.handshakeTask = nil } }
                            guard !connectContinuation.isCompleted else { return }
                            do {
                                var authenticatedByHello = false
                                if self.preferredProtocolVersion == .resp3 {
                                    authenticatedByHello = try await self.performResp3Handshake()
                                }

                                // Authenticate if credentials are provided.
                                let user = self.username ?? ""
                                let pw = self.password ?? ""
                                if (!user.isEmpty || !pw.isEmpty) && !authenticatedByHello {
                                    let result: RESPValue
                                    if !user.isEmpty {
                                        result = try await self.send("AUTH", user, pw)
                                    } else {
                                        result = try await self.send("AUTH", pw)
                                    }
                                    if case .error(let msg) = result {
                                        self.updateConnectionState(isConnected: true, lastError: msg)
                                        throw RedisError.commandError(msg)
                                    }
                                }
                                self.logNegotiatedProtocol(authenticatedByHello: authenticatedByHello)

                                connectContinuation.complete(.success(()))
                            } catch {
                                self.updateConnectionState(isConnected: false, lastError: error.localizedDescription)
                                connectContinuation.complete(.failure(error))
                            }
                        }
                        self.state.withLock { $0.handshakeTask = handshakeTask }
                    case .failed(let error):
                        self.updateConnectionState(isConnected: false, lastError: error.localizedDescription)
                        connectContinuation.complete(.failure(error))
                    case .waiting(let error):
                        self.updateConnectionState(lastError: error.localizedDescription)
                    case .cancelled:
                        self.updateConnectionState(isConnected: false)
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

    func disconnect() {
        disconnect(publishState: true)
    }

    func disconnect(publishState: Bool) {
        let disconnectAction = {
            self.cancelConnectionOnQueue()
            self.clearClientIdentity()
        }

        if DispatchQueue.getSpecific(key: queueKey) == true {
            disconnectAction()
        } else {
            queue.sync(execute: disconnectAction)
        }

        guard publishState else { return }
        updateConnectionState(isConnected: false)
    }

    /// Deletes the temporary keychain backing the client TLS identity (if any)
    /// and drops the retained bundle so the private key is no longer kept alive.
    private func clearClientIdentity() {
        if let keychain = clientIdentityBundle.withLock({ $0?.keychain }) {
            SecKeychainDelete(keychain)
        }
        clientIdentityBundle.withLock { $0 = nil }
    }

    func updateConnectionState(isConnected: Bool? = nil, lastError: String? = nil) {
        state.withLock {
            if let isConnected {
                $0.isConnected = isConnected
            }
            if let lastError {
                $0.lastError = lastError
            }
        }
    }

}
