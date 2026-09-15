import SwiftUI

// MARK: - Workspace View

struct WorkspaceView: View {
    @Environment(TabState.self) private var tab

    var body: some View {
        Group {
            switch tab.currentSection {
            case .keys: KeysView().transition(.opacity)
            case .functions: FunctionsView().transition(.opacity)
            case .shell: ShellView().transition(.opacity)
            case .profiler: ProfilerView().transition(.opacity)
            case .slowLog: SlowLogView().transition(.opacity)
            case .databaseAnalysis: DatabaseAnalysisView().transition(.opacity)
            case .serverInfo: ServerInfoView().transition(.opacity)
            }
        }
        .animation(.default, value: tab.currentSection)
    }
}
