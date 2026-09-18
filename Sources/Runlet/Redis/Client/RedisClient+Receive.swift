import Foundation
import Network

// MARK: - Receive Loop

/// Inbound half of `RedisClient`: the NWConnection receive loop, RESP stream
/// dispatch to pending completions, and cancellation bookkeeping.
extension RedisClient {
    private func removePendingCompletion(_ completion: PendingCommand) {
        removePendingCompletion(id: completion.id)
    }

    private func removePendingCompletion(id: UUID) {
        state.withLock { state in
            if let index = state.pendingCompletions.firstIndex(where: { $0.id == id }) {
                state.pendingCompletions.remove(at: index)
            }
        }
    }

    private func cancelPendingResponseSlot(id: UUID) {
        state.withLock { state in
            if let index = state.pendingCompletions.firstIndex(where: { $0.id == id }) {
                state.pendingCompletions[index] = .cancelled(id)
            }
        }
    }

    func failPendingCompletion(_ completion: PendingCommand, with error: Error) {
        removePendingCompletion(completion)
        completion.complete(.failure(error))
    }

    func cancelPendingCompletion(_ completion: PendingCommand) {
        let cancelAction: @Sendable () -> Void = {
            let shouldRemoveFromQueue = completion.cancel()
            if shouldRemoveFromQueue {
                self.removePendingCompletion(completion)
            } else {
                self.cancelPendingResponseSlot(id: completion.id)
            }
        }

        if DispatchQueue.getSpecific(key: queueKey) == true {
            cancelAction()
        } else {
            queue.async(execute: cancelAction)
        }
    }

    func cancelPendingCompletions(_ batch: PendingCommandBatch) {
        for command in batch.cancel() {
            cancelPendingCompletion(command)
        }
    }

    private func receiveLoop() {
        queue.async { [weak self] in
            guard let self else { return }
            let connection = self.state.withLock { $0.connection }
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.queue.async {
                        self.state.withLock {
                            $0.parser.append(data)
                        }
                        self.processBuffer()
                    }
                }
                if error == nil && !isComplete {
                    self.receiveLoop()
                } else {
                    self.queue.async {
                        let finishError: Error = error ?? RedisError.notConnected
                        self.completePendingCommands(with: finishError)
                        self.state.withLock {
                            $0.parser = RESPParser()
                        }
                        self.finishMonitor(with: finishError)
                    }
                    self.updateConnectionState(isConnected: false, lastError: error?.localizedDescription)
                }
            }
        }
    }

    private func completePendingCommands(with error: Error) {
        let pendingCompletions = state.withLock {
            let pendingCompletions = $0.pendingCompletions.compactMap(\.command)
            $0.pendingCompletions.removeAll()
            return pendingCompletions
        }
        for completion in pendingCompletions {
            completion.complete(.failure(error))
        }
    }

    func cancelConnectionOnQueue(error: Error = RedisError.notConnected) {
        let (connection, handshakeTask) = state.withLock {
            let connection = $0.connection
            let handshakeTask = $0.handshakeTask
            $0.connection = nil
            $0.handshakeTask = nil
            $0.parser = RESPParser()
            return (connection, handshakeTask)
        }
        handshakeTask?.cancel()
        connection?.cancel()
        completePendingCommands(with: error)
        finishMonitor(with: error)
    }

    func cancelConnectionForCancellation() {
        let cancelAction: @Sendable () -> Void = {
            self.cancelConnectionOnQueue(error: CancellationError())
        }

        if DispatchQueue.getSpecific(key: queueKey) == true {
            cancelAction()
        } else {
            queue.async(execute: cancelAction)
        }
        updateConnectionState(isConnected: false)
    }

    func startReceiving() {
        receiveLoop()
    }

    private func processBuffer() {
        let completedCommands: [(PendingCommand, RESPValue)]
        let pushedMessages: [RESPValue]
        let monitorLines: [String]
        let monitorFailure: Error?
        let protocolFailure: Error?
        (completedCommands, pushedMessages, monitorLines, monitorFailure, protocolFailure) = state.withLock {
            var completedCommands: [(PendingCommand, RESPValue)] = []
            var pushedMessages: [RESPValue] = []
            var monitorLines: [String] = []
            var monitorFailure: Error?
            var protocolFailure: Error?
            do {
                while let message = try $0.parser.parse() {
                    switch message {
                    case .response(let value):
                        if !$0.pendingCompletions.isEmpty {
                            let pendingResponse = $0.pendingCompletions.removeFirst()
                            if let completion = pendingResponse.command {
                                completedCommands.append((completion, value))
                            }
                        } else if $0.isMonitoring, let line = value.string {
                            // Unsolicited MONITOR output: no in-flight request.
                            monitorLines.append(line)
                        } else if $0.isMonitoring, case .error(let message) = value {
                            monitorFailure = RedisError.commandError(message)
                        }
                    case .push(let value):
                        // Unsolicited RESP3 push: never matches an in-flight request.
                        pushedMessages.append(value)
                    }
                }
                $0.parser.compact()
            } catch {
                // A hard protocol violation: the stream is desynchronized and
                // more data can never fix it, so fail everything and reconnect.
                let pending = $0.pendingCompletions.compactMap(\.command)
                $0.pendingCompletions.removeAll()
                $0.parser = RESPParser()
                let failure = RedisError.commandError("RESP protocol error: \(error.localizedDescription)")
                for completion in pending {
                    completion.complete(.failure(failure))
                }
                if $0.isMonitoring {
                    monitorFailure = failure
                }
                protocolFailure = error
            }
            return (completedCommands, pushedMessages, monitorLines, monitorFailure, protocolFailure)
        }

        for (completion, value) in completedCommands {
            completion.complete(.success(value))
        }

        if !monitorLines.isEmpty {
            let continuation = state.withLock { $0.monitorContinuation }
            for line in monitorLines {
                continuation?.yield(line)
            }
        }
        if let monitorFailure {
            finishMonitor(with: monitorFailure)
        }

        if let protocolFailure {
            cancelConnectionOnQueue(
                error: RedisError.commandError("RESP protocol error: \(protocolFailure.localizedDescription)"))
        }

        guard !pushedMessages.isEmpty else { return }
        let handler = state.withLock { $0.pushHandler }
        for message in pushedMessages {
            if let handler {
                handler(message)
            } else {
                AppLogger.debug("received unsolicited RESP3 push message", category: "Redis")
            }
        }
    }

}
