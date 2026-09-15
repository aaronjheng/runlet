import SwiftUI

// MARK: - ConnectionEnvironment Presentation

/// View-layer mapping for `ConnectionEnvironment`.
///
/// Lives here (not in `Connection/Models/`) so the domain model stays free
/// of SwiftUI: models must never import the view framework, per the
/// dependency rule.
extension ConnectionEnvironment {
    var color: Color {
        switch self {
        case .unspecified: return .secondary
        case .development: return AppColor.success
        case .testing: return AppColor.info
        case .staging: return AppColor.warning
        case .production: return AppColor.error
        }
    }

    var icon: String {
        switch self {
        case .unspecified: return "circle"
        case .development: return "hammer"
        case .testing: return "testtube.2"
        case .staging: return "flask"
        case .production: return "shield"
        }
    }

    var badgeForegroundColor: Color { color }

    var badgeBackgroundColor: Color { AppColor.badgeBackground(color) }
}
