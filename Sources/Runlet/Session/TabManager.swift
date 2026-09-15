import Observation

@MainActor
@Observable
class TabManager {
    var tabStates: [TabState] = []

    func createTab() -> TabState {
        let state = TabState()
        tabStates.append(state)
        return state
    }

    func closeTab(_ state: TabState) {
        state.disconnect()
        tabStates.removeAll { $0.id == state.id }
    }

    func tabIndex(for state: TabState) -> Int? {
        tabStates.firstIndex(where: { $0.id == state.id })
    }
}
