import Foundation

// MARK: - Shell History

struct ShellHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let command: String
    let result: String
    let timestamp: Date
    let isError: Bool

    init(
        id: UUID = UUID(),
        command: String,
        result: String,
        timestamp: Date,
        isError: Bool
    ) {
        self.id = id
        self.command = command
        self.result = result
        self.timestamp = timestamp
        self.isError = isError
    }
}
