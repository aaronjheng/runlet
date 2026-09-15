import Foundation
import Network

// MARK: - Send / Pipeline

/// Outbound half of `RedisClient`: single commands (with per-command timeout
/// except blocking commands) and pipelined batches.
extension RedisClient {
    func send(_ args: String...) async throws -> RESPValue {
        try await send(args)
    }

    func send(_ args: [String]) async throws -> RESPValue {
        guard !args.isEmpty else {
            throw RedisError.commandError("Redis command is empty")
        }
        let data = RESPEncoder.encode(args, version: negotiatedProtocolVersion)
        return try await sendEncodedCommand(data, isBlocking: Self.isBlockingCommand(args))
    }

    /// Commands that legitimately block on the server; a command timeout would
    /// kill them mid-wait, so they are sent without one.
    private static let blockingCommands: Set<String> = [
        "BLPOP", "BRPOP", "BRPOPLPUSH", "BLMOVE", "BZPOPMIN", "BZPOPMAX",
        "SUBSCRIBE", "PSUBSCRIBE", "MONITOR",
    ]

    private static func isBlockingCommand(_ args: [String]) -> Bool {
        guard let command = args.first?.uppercased() else { return false }
        if blockingCommands.contains(command) {
            return true
        }
        if command == "XREAD" || command == "XREADGROUP" {
            return args.contains { $0.uppercased() == "BLOCK" }
        }
        return false
    }

    func sendEncodedCommand(_ data: Data, isBlocking: Bool) async throws -> RESPValue {
        if !isBlocking {
            return try await withTimeout(commandTimeout, context: "Redis command") {
                try await self.sendEncodedCommandUntimed(data)
            }
        }
        return try await sendEncodedCommandUntimed(data)
    }

    private func sendEncodedCommandUntimed(_ data: Data) async throws -> RESPValue {
        try Task.checkCancellation()
        guard isConnected else {
            throw RedisError.notConnected
        }

        let pendingCompletion = PendingCommand()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCompletion.setContinuation(continuation)

                self.queue.async {
                    guard !pendingCompletion.isCompleted else { return }
                    guard let connection = self.state.withLock({ $0.connection }) else {
                        pendingCompletion.complete(.failure(RedisError.notConnected))
                        return
                    }
                    guard pendingCompletion.reserveResponseSlot() else { return }

                    self.state.withLock {
                        $0.pendingCompletions.append(.command(pendingCompletion))
                    }

                    connection.send(
                        content: data,
                        completion: .contentProcessed { error in
                            if let error = error {
                                self.queue.async {
                                    self.failPendingCompletion(pendingCompletion, with: error)
                                }
                            }
                        })
                }
            }
        } onCancel: {
            self.cancelPendingCompletion(pendingCompletion)
        }
    }

    func sendPipeline(_ commands: [[String]]) async throws -> [RESPValue] {
        try Task.checkCancellation()
        guard isConnected else {
            throw RedisError.notConnected
        }
        guard !commands.isEmpty else { return [] }
        guard commands.allSatisfy({ !$0.isEmpty }) else {
            throw RedisError.commandError("Redis command is empty")
        }

        let data = commands.reduce(into: Data()) { encodedData, command in
            encodedData.append(RESPEncoder.encode(command, version: negotiatedProtocolVersion))
        }
        return try await withTimeout(commandTimeout, context: "Redis pipeline") {
            try await self.sendPipelineUntimed(data, count: commands.count)
        }
    }

    private func sendPipelineUntimed(_ data: Data, count: Int) async throws -> [RESPValue] {
        try Task.checkCancellation()
        guard isConnected else {
            throw RedisError.notConnected
        }

        let pendingBatch = PendingCommandBatch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pipeline = PendingPipeline(count: count, continuation: continuation)
                let pendingCommands = (0..<count).map { index in
                    PendingCommand(completion: { result in
                        pipeline.complete(index: index, with: result)
                    })
                }

                guard pendingBatch.setCommands(pendingCommands) else {
                    for pendingCommand in pendingCommands {
                        pendingCommand.complete(.failure(CancellationError()))
                    }
                    return
                }

                self.queue.async {
                    guard pendingCommands.allSatisfy({ !$0.isCompleted }) else { return }
                    guard let connection = self.state.withLock({ $0.connection }) else {
                        for pendingCommand in pendingCommands {
                            pendingCommand.complete(.failure(RedisError.notConnected))
                        }
                        return
                    }
                    for pendingCommand in pendingCommands {
                        guard pendingCommand.reserveResponseSlot() else { return }
                    }

                    self.state.withLock {
                        $0.pendingCompletions.append(contentsOf: pendingCommands.map(PendingResponse.command))
                    }

                    connection.send(
                        content: data,
                        completion: .contentProcessed { error in
                            if let error = error {
                                self.queue.async {
                                    for pendingCommand in pendingCommands {
                                        self.failPendingCompletion(pendingCommand, with: error)
                                    }
                                }
                            }
                        })
                }
            }
        } onCancel: {
            self.cancelPendingCompletions(pendingBatch)
        }
    }

}
