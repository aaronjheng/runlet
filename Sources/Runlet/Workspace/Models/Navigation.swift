import Foundation

// MARK: - Navigation

enum WorkspaceSection: String, CaseIterable {
    case keys = "Keys"
    case functions = "Functions"
    case shell = "Shell"
    case profiler = "Profiler"
    case slowLog = "Slow Log"
    case databaseAnalysis = "Analysis"
    case serverInfo = "Server Info"

    var icon: String {
        switch self {
        case .keys: return "key"
        case .functions: return "curlybraces"
        case .shell: return "terminal"
        case .profiler: return "waveform.path.ecg"
        case .slowLog: return "hourglass"
        case .databaseAnalysis: return "chart.pie"
        case .serverInfo: return "info.circle"
        }
    }
}

struct RedisServerCapability: Identifiable, Hashable {
    let name: String
    let version: String?
    let details: [RedisServerCapabilityDetail]

    var id: String {
        ([name, version ?? ""] + details.map { "\($0.name)=\($0.value)" }).joined(separator: "|")
    }
}

struct RedisServerCapabilityDetail: Hashable {
    let name: String
    let value: String
}
