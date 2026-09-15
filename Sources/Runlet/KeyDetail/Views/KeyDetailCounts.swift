import Foundation

// MARK: - Key Detail Counts

func detailCountText(loaded: Int, total: Int?, noun: String) -> String {
    if let total {
        return "Showing \(loaded) of \(total) \(noun)"
    }
    return "\(loaded) \(noun)"
}
