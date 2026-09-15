import AppKit
import SwiftUI

// MARK: - Status Views

struct Badge: View {
    let text: String
    var systemImage: String?
    var foregroundColor: Color = .secondary
    var backgroundColor: Color = AppColor.subtleBackground
    var isLoading: Bool = false

    var body: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .padding(.horizontal, AppSpacing.mini)
                .padding(.vertical, AppSpacing.xxSmall)
                .frame(minWidth: 42)
        } else {
            HStack(spacing: AppSpacing.xxSmall) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(text)
            }
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, AppSpacing.mini)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct ErrorBanner: View {
    enum Severity {
        case error
        case warning

        var icon: String { "exclamationmark.triangle.fill" }
        var color: Color {
            switch self {
            case .error: AppColor.error
            case .warning: AppColor.warning
            }
        }
        var background: Color { color.opacity(0.12) }
    }

    let message: String
    var severity: Severity = .error
    var dismissAction: (() -> Void)?

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: severity.icon)
                .foregroundStyle(severity.color)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
            Spacer()
            if let dismissAction {
                Button("Dismiss", systemImage: "xmark") {
                    dismissAction()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Dismiss")
            }
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.mini)
        .background(severity.background)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
    }
}

struct LoadingState: View {
    let message: String

    var body: some View {
        VStack(spacing: AppSpacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
    }
}

struct DeleteIconButton: View {
    let action: () -> Void
    var helpText: String?
    var size: IconButtonSize = .regular

    init(action: @escaping () -> Void, helpText: String? = nil, size: IconButtonSize = .regular) {
        self.action = action
        self.helpText = helpText
        self.size = size
    }

    var body: some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            action()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(IconButtonStyle(isDestructive: true, size: size))
        // Custom ButtonStyles can't see the button role, so the red must
        // be explicit — otherwise the icon renders in primary.
        .foregroundStyle(AppColor.error)
        .help(helpText ?? "Delete")
    }
}

/// Shared auto-refresh interval options (seconds) for `RefreshControl`.
/// SlowLog's config menu is built from the same list so every panel
/// offers identical choices. Pure Foundation — safe to use from Models.
enum AutoRefreshInterval {
    static let options: [TimeInterval] = [5, 10, 15, 30, 60]

    static func title(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds.isMultiple(of: 60) {
            return "\(totalSeconds / 60)m"
        }
        return "\(totalSeconds)s"
    }
}

struct RefreshControl: View {
    @Binding var autoRefreshInterval: TimeInterval
    let isLoading: Bool
    let intervals: [TimeInterval]
    let onRefresh: () -> Void

    private var isAutoRefreshEnabled: Bool {
        autoRefreshInterval > 0
    }

    @State private var isRefreshHovering = false
    @State private var isMenuHovering = false

    var body: some View {
        HStack(spacing: 0) {
            refreshButton
            separator
            intervalMenu
        }
        .frame(height: AppSize.refreshControlHeight)
        .toolbarCapsule()
        .opacity(isLoading ? 0.5 : 1)
    }

    private var refreshButton: some View {
        Button {
            onRefresh()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .imageScale(.medium)
                .foregroundStyle(.primary)
                .frame(width: AppSize.refreshButtonWidth, height: AppSize.refreshControlHeight)
                .contentShape(Rectangle())
                .background(
                    isRefreshHovering && !isLoading
                        ? Color.primary.opacity(0.08)
                        : Color.clear
                )
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: AppRadius.medium,
                        bottomLeadingRadius: AppRadius.medium,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isRefreshHovering = $0 }
        .help("Refresh")
    }

    private var separator: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 0.5, height: AppSize.refreshSeparatorHeight)
    }

    private var intervalMenu: some View {
        Menu {
            Button {
                autoRefreshInterval = 0
            } label: {
                menuItemLabel(text: "Off", checked: !isAutoRefreshEnabled)
            }
            Divider()
            ForEach(intervals, id: \.self) { interval in
                Button {
                    autoRefreshInterval = interval
                } label: {
                    menuItemLabel(
                        text: AutoRefreshInterval.title(interval),
                        checked: isAutoRefreshEnabled && autoRefreshInterval == interval
                    )
                }
            }
        } label: {
            HStack(spacing: AppSpacing.xxSmall) {
                if isAutoRefreshEnabled {
                    Text(AutoRefreshInterval.title(autoRefreshInterval))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .imageScale(.medium)
                    .foregroundStyle(isMenuHovering && !isLoading ? .primary : .secondary)
            }
            .padding(.horizontal, AppSpacing.mini)
            .frame(height: AppSize.refreshControlHeight)
            .contentShape(Rectangle())
            .background(
                isMenuHovering && !isLoading
                    ? Color.primary.opacity(0.08)
                    : Color.clear
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: AppRadius.medium,
                    topTrailingRadius: AppRadius.medium,
                    style: .continuous
                )
            )
            .animation(AppAnimation.quick, value: isMenuHovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isLoading)
        .onHover { isMenuHovering = $0 }
        .help(isAutoRefreshEnabled ? "Auto refresh every \(AutoRefreshInterval.title(autoRefreshInterval))" : "Auto refresh off")
    }

    private func menuItemLabel(text: String, checked: Bool) -> some View {
        Text(checked ? "\(text)  \u{2713}" : text)
    }
}

/// Standalone refresh button using the same styling as `RefreshControl`'s
/// button, for places that only need a manual refresh (no auto-refresh menu).
struct RefreshButton: View {
    let isLoading: Bool
    let onRefresh: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onRefresh) {
            Label("Refresh", systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .imageScale(.medium)
                .foregroundStyle(.primary)
                .frame(width: AppSize.refreshButtonWidth, height: AppSize.refreshControlHeight)
                .contentShape(Rectangle())
                .background(
                    isHovering && !isLoading
                        ? Color.primary.opacity(0.08)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovering = $0 }
        .help("Refresh")
        .toolbarCapsule()
        .opacity(isLoading ? 0.5 : 1)
    }
}
