import Foundation
import Synchronization

// MARK: - Pending Completion State Machines

/// Continuation plumbing for `RedisClient`: one-shot connect continuation,
/// per-command completions, pipeline batches, and the pending-response queue
/// entry. Self-contained: each type guards its own state with a `Mutex`.
extension RedisClient {
    final class ConnectContinuationState: Sendable {
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

    final class PendingCommand: Sendable {
        private typealias CommandCompletion = @Sendable (Result<RESPValue, Error>) -> Void

        private struct State: Sendable {
            var completion: CommandCompletion?
            var result: Result<RESPValue, Error>?
            var isQueuedForResponse = false
        }

        let id = UUID()
        private let state = Mutex(State())

        var isCompleted: Bool {
            state.withLock { $0.result != nil }
        }

        init(_ continuation: CheckedContinuation<RESPValue, Error>) {
            setContinuation(continuation)
        }

        init() {}

        func setContinuation(_ continuation: CheckedContinuation<RESPValue, Error>) {
            setCompletion { result in
                Self.resume(continuation, with: result)
            }
        }

        init(completion: @escaping @Sendable (Result<RESPValue, Error>) -> Void) {
            setCompletion(completion)
        }

        func reserveResponseSlot() -> Bool {
            state.withLock {
                guard $0.result == nil else { return false }
                $0.isQueuedForResponse = true
                return true
            }
        }

        func complete(_ result: Result<RESPValue, Error>) {
            let completion: (@Sendable (Result<RESPValue, Error>) -> Void)? = state.withLock {
                guard $0.result == nil else { return nil }
                $0.result = result
                let completion = $0.completion
                $0.completion = nil
                return completion
            }
            completion?(result)
        }

        func cancel() -> Bool {
            let (completion, shouldRemoveFromQueue) = state.withLock { state -> (CommandCompletion?, Bool) in
                let shouldRemoveFromQueue = !state.isQueuedForResponse
                guard state.result == nil else { return (nil, shouldRemoveFromQueue) }
                state.result = Result<RESPValue, Error>.failure(CancellationError())
                let completion = state.completion
                state.completion = nil
                return (completion, shouldRemoveFromQueue)
            }
            completion?(Result<RESPValue, Error>.failure(CancellationError()))
            return shouldRemoveFromQueue
        }

        private func setCompletion(_ completion: @escaping CommandCompletion) {
            let result = state.withLock { state -> Result<RESPValue, Error>? in
                if let result = state.result {
                    return result
                }
                state.completion = completion
                return nil
            }

            if let result {
                completion(result)
            }
        }

        private static func resume(
            _ continuation: CheckedContinuation<RESPValue, Error>,
            with result: Result<RESPValue, Error>
        ) {
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    final class PendingCommandBatch: Sendable {
        private struct State: Sendable {
            var isCancelled = false
            var commands: [PendingCommand] = []
        }

        private let state = Mutex(State())

        func setCommands(_ commands: [PendingCommand]) -> Bool {
            state.withLock {
                guard !$0.isCancelled else { return false }
                $0.commands = commands
                return true
            }
        }

        func cancel() -> [PendingCommand] {
            state.withLock {
                $0.isCancelled = true
                return $0.commands
            }
        }
    }

    final class PendingPipeline: Sendable {
        private typealias Completion = (
            continuation: CheckedContinuation<[RESPValue], Error>,
            result: Result<[RESPValue], Error>
        )

        private struct State: Sendable {
            var results: [RESPValue?]
            var remainingCount: Int
            var continuation: CheckedContinuation<[RESPValue], Error>?
        }

        private let state: Mutex<State>

        init(count: Int, continuation: CheckedContinuation<[RESPValue], Error>) {
            state = Mutex(
                State(
                    results: Array(repeating: nil, count: count),
                    remainingCount: count,
                    continuation: continuation
                )
            )
        }

        func complete(index: Int, with result: Result<RESPValue, Error>) {
            let completion: Completion? = state.withLock { state in
                if let storedContinuation = state.continuation {
                    switch result {
                    case .success(let value):
                        state.results[index] = value
                        state.remainingCount -= 1
                        if state.remainingCount == 0 {
                            var values: [RESPValue] = []
                            values.reserveCapacity(state.results.count)
                            var missingResponse = false
                            for response in state.results {
                                guard let response else {
                                    missingResponse = true
                                    break
                                }
                                values.append(response)
                            }

                            state.continuation = nil
                            return (
                                storedContinuation,
                                missingResponse
                                    ? .failure(RedisError.parseError("Missing Redis pipeline response"))
                                    : .success(values)
                            )
                        }
                    case .failure(let error):
                        state.continuation = nil
                        return (storedContinuation, .failure(error))
                    }
                }
                return nil
            }

            guard let completion else { return }
            switch completion.result {
            case .success(let values):
                completion.continuation.resume(returning: values)
            case .failure(let error):
                completion.continuation.resume(throwing: error)
            }
        }
    }

    enum PendingResponse: Sendable {
        case command(PendingCommand)
        case cancelled(UUID)

        var id: UUID {
            switch self {
            case .command(let command):
                command.id
            case .cancelled(let id):
                id
            }
        }

        var command: PendingCommand? {
            guard case .command(let command) = self else { return nil }
            return command
        }
    }

}
