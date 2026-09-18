import Foundation

// MARK: - MONITOR Mode

/// MONITOR streaming for `RedisClient`.
///
/// A connection that enters MONITOR mode becomes a dedicated push stream:
/// after the server replies `+OK`, every subsequent message is unsolicited
/// MONITOR output that matches no in-flight request. `processBuffer()` routes
/// those lines here instead of dropping them.
///
/// Callers must use a dedicated `RedisClient` per monitored node (a fresh
/// instance with `preferredProtocolVersion == .resp2`, mirroring the plain
/// AUTH handshake MONITOR expects) and never send other commands on it
/// afterwards. The profiler owns one such client per node and tears it down
/// via `disconnect()`.
extension RedisClient {
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
            if !isConnected {
                try await connect()
            }
            state.withLock { $0.isMonitoring = true }

            let result = try await send(["MONITOR"])
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

    func finishMonitor(with error: Error?) {
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
}
