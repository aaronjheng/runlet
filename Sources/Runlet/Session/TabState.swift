import AppKit
import Foundation
import Observation

// MARK: - Tab State

enum ConnectionPanel: Equatable {
    case welcome
    case editConnection(RedisConnectionConfig)
    case newConnection

    static func == (lhs: ConnectionPanel, rhs: ConnectionPanel) -> Bool {
        switch (lhs, rhs) {
        case (.welcome, .welcome): return true
        case (.newConnection, .newConnection): return true
        case (.editConnection(let leftConfig), .editConnection(let rightConfig)): return leftConfig.id == rightConfig.id
        default: return false
        }
    }
}

@MainActor
@Observable
class TabState {
    let id = UUID()
    @ObservationIgnored
    weak var window: NSWindow?

    var activeSession: (any RedisSession)?
    var isConnecting = false
    var connectionError: String?
    var failedConnection: RedisConnectionConfig?
    var selectedConnection: RedisConnectionConfig?
    var pendingConnection: RedisConnectionConfig?

    var keys: [RedisKeyEntry] = [] {
        didSet { keyNamespaceTreeCache = nil }
    }
    /// Memoized namespace tree for the current keys + filter + separator.
    /// Invalidation happens through the `didSet` hooks above; without it,
    /// every selection change rebuilt the tree O(n log n) in the view body.
    @ObservationIgnored
    var keyNamespaceTreeCache: KeyNamespaceTree?
    var selectedKey: RedisKeyEntry?
    /// Monotonic token bumped whenever a fresh key-detail load begins (select,
    /// search, ordering change). In-flight loads capture it and discard their
    /// results once it changes, preventing concurrent loads from clobbering the
    /// detail state of the currently selected key.
    var keyDetailGeneration = 0
    var keyDetail: String = ""
    var keyDetailRows: [(String, String)] = []
    var keyType: String = ""
    var valueSize: Int?
    var keyDetailTotalCount: Int?
    var keyDetailError: String?
    var keyDetailOffset = 0
    var keyDetailCursor: String = "0"
    var keyDetailHasMoreRows = false
    var keyDetailSearchText = ""
    /// True when the displayed string value was truncated via GETRANGE because
    /// it exceeded `stringDetailTruncationLimit` bytes.
    var keyDetailTruncated = false
    var keyDetailOrder: KeyDetailOrder = .ascending
    var isLoadingKeys = false
    var isLoadingDetail = false
    var scanCursor: String = "0"
    var hasMoreKeys = true
    var keyFilter: String = "*"
    var keyTypeFilter: String = "" {
        didSet { keyNamespaceTreeCache = nil }
    }
    var keyScanCount = 500
    var keyTotalCount: Int?
    var keyScannedCount = 0
    var keyScanIterationCount = 0
    var keyScanLimitReached = false
    var isNamespaceGroupingEnabled = false
    var namespaceSeparator = ":" {
        didSet { keyNamespaceTreeCache = nil }
    }
    var stringValueFormat: StringValueFormat = .json
    var keyDetailLastRefreshedAt: Date?

    var shellHistory: [ShellHistoryEntry] = []
    /// Connection whose history `shellHistory` was loaded from. Writebacks use
    /// this id so a mid-flight connection switch can never store under the
    /// wrong connection key.
    var shellHistoryConnectionID: UUID?
    var shellInput: String = ""
    var shellSession: (any RedisSession)?

    var slowLogEntries: [SlowLogEntry] = []
    var slowLogConfig = SlowLogConfig()
    var isLoadingSlowLog = false
    var slowLogError: String?
    var slowLogFetchCount = 128

    var analysis: DatabaseAnalysis?
    var isLoadingAnalysis = false
    var analysisError: String?
    var analysisTaskHandle: Task<Void, Never>?
    /// Monotonic token invalidating in-flight analysis when the connection
    /// changes, so stale results can never be written back.
    var analysisGeneration = 0
    /// The off-main-actor worker that performs the actual analysis work. Held
    /// separately so cancellation (via `cancelAnalysis()`) reaches the worker's
    /// `try Task.checkCancellation()` checkpoints.
    var analysisTask: Task<DatabaseAnalysis, Error>?

    var profilerEntries: [RedisProfilerEntry] = []
    var profilerCapturedCount = 0
    var profilerError: String?
    var isProfilerRunning = false
    var isProfilerStarting = false

    var serverInfo: [String: [String: String]] = [:]
    var serverCapabilities: [RedisServerCapability] = []
    var clusterInfo: [String: String] = [:]
    var clusterNodes: [RedisClusterNodeSummary] = []
    var serverInfoError: String?
    var selectedServerInfoNode: RedisEndpoint?
    var isLoadingServerInfo = false

    var functionLibraries: [RedisFunctionLibrary] = []
    var isLoadingFunctions = false
    var functionsError: String?
    var selectedFunctionLibrary: RedisFunctionLibrary?

    var functionCallHistory: [RedisFunctionCallResult] = []
    var isCallingFunction = false

    var currentSection: WorkspaceSection = .keys
    var connectionPanel: ConnectionPanel = .welcome

    var connectTask: Task<Void, Never>?
    /// Monotonic token bumped on every `connect()`. Stale connect tasks compare
    /// their captured generation against this before touching shared resources,
    /// so a cancelled/superseded connect can never kill a newer connection.
    var connectGeneration = 0
    var sshTunnel: SSHTunnel?
    /// Tunnel created specifically for the shell session when the main
    /// connection has none (kept separate so it never clobbers the main slot).
    var shellSSHTunnel: SSHTunnel?
    var sshClusterTunnelManager: SSHClusterTunnelManager?
    var isScanningKeysRequest = false
    var pendingResetScan = false
    /// A non-reset "load more" that arrived while a scan was in flight.
    var pendingLoadMore = false
    var profilerTask: Task<Void, Never>?
    var profilerMonitorClients: [RedisClient] = []
    var profilerMonitorTasks: RedisProfilerTaskBag?
    var profilerSSHTunnel: SSHTunnel?
    var profilerClusterTunnelManager: SSHClusterTunnelManager?
    var profilerGeneration = 0
    let profilerMaxEntries = 2_000
    let keyMetadataPipelineBatchSize = 50
    let keyDetailPageSize = 100
    let stringDetailTruncationLimit = 1_000_000
    let keyPatternScanIterationLimit = 1_000
    let shellHistoryLimit = 200

    var windowTitle: String {
        if let config = selectedConnection {
            return config.name
        }
        return "Runlet"
    }

}
