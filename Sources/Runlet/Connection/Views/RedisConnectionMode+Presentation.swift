import SwiftUI

// MARK: - RedisConnectionMode Presentation

/// View-layer mapping for `RedisConnectionMode`.
///
/// Lives here (not in `Redis/`) so the domain model stays free of SwiftUI:
/// `Redis/` must never import the view framework, per the dependency rule.
extension RedisConnectionMode {
    var badgeForegroundColor: Color {
        switch self {
        case .standalone: return .secondary
        case .cluster: return .accentColor
        }
    }

    var badgeBackgroundColor: Color {
        switch self {
        case .standalone: return AppColor.subtleBackground
        case .cluster: return AppColor.badgeBackground(.accentColor)
        }
    }
}
