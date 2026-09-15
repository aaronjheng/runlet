import SwiftUI

// MARK: - Connection Row

struct ConnectionRow: View {
    let config: RedisConnectionConfig
    let isConnected: Bool
    var isSelected: Bool = false
    /// Hover is driven by the owner's `DoubleClickHandler` overlay, which
    /// covers the row and occludes `.onHover` — do not track hover here.
    var isHovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            HStack(spacing: AppSpacing.xSmall) {
                Text(config.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: AppSpacing.small)
                if config.environment != .unspecified {
                    Badge(
                        text: config.environment.rawValue,
                        systemImage: config.environment.icon,
                        foregroundColor: config.environment.badgeForegroundColor,
                        backgroundColor: config.environment.badgeBackgroundColor
                    )
                    .help("Environment: \(config.environment.rawValue)")
                }
                Badge(
                    text: config.mode.title,
                    foregroundColor: config.mode.badgeForegroundColor,
                    backgroundColor: config.mode.badgeBackgroundColor
                )
                .help("Connection mode: \(config.mode.title)")
            }
            Text(config.address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, AppSpacing.xSmall)
        .contentShape(Rectangle())
        .sidebarHoverWash(active: isHovering && !isSelected)
        .animation(AppAnimation.quick, value: isHovering)
        .help("Single-click to edit — double-click to connect")
        .accessibilityLabel("\(config.name), \(config.address)")
    }
}
