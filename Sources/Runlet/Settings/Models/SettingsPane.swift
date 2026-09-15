import Foundation

// MARK: - Settings Pane

enum SettingsPane: Hashable, CaseIterable {
    case application
    case appearance

    var title: String {
        switch self {
        case .application: return "Application"
        case .appearance: return "Appearance"
        }
    }

    var icon: String {
        switch self {
        case .application: return "gearshape"
        case .appearance: return "paintbrush"
        }
    }
}
