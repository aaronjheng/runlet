import Foundation

// MARK: - Connection Environment

enum ConnectionEnvironment: String, Codable, CaseIterable {
    case unspecified = "Unspecified"
    case development = "Development"
    case testing = "Testing"
    case staging = "Staging"
    case production = "Production"
}
