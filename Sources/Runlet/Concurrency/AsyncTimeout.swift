import Foundation

enum OperationTimeoutError: LocalizedError {
    case timedOut(context: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let context, let seconds):
            return String(format: "\(context) timed out after %gs", seconds)
        }
    }
}

func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    context: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw OperationTimeoutError.timedOut(context: context, seconds: seconds)
        }

        guard let result = try await group.next() else {
            throw OperationTimeoutError.timedOut(context: context, seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}
