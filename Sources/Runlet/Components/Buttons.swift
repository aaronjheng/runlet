import AppKit
import SwiftUI

// MARK: - Stable screenshot button styles

/// A primary button style that renders reliably in off-screen captures.
/// Use this in place of `.buttonStyle(.borderedProminent)`.
/// Hover and press feedback are driven by transient state that is idle during
/// off-screen renders, so captured output stays in the stable rest appearance.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.mini)
            .font(.system(.body, design: .default))
            .foregroundStyle(.white)
            .background(.tint)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .brightness(pressedBrightness(configuration))
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .animation(AppAnimation.quick, value: isHovering)
    }

    private func pressedBrightness(_ configuration: Configuration) -> Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return -0.08 }
        return isHovering ? 0.12 : 0
    }
}

/// A secondary button style that renders reliably in off-screen captures.
/// Use this in place of `.buttonStyle(.bordered)`.
/// Hover and press feedback are driven by transient state that is idle during
/// off-screen renders, so captured output stays in the stable rest appearance.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.mini)
            .font(.system(.body, design: .default))
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(.background.secondary)
            }
            .background {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled && !configuration.isPressed ? 0.06 : 0))
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovering && isEnabled ? 0.14 : 0), lineWidth: 1)
            )
            .brightness(configuration.isPressed && isEnabled ? -0.06 : 0)
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .animation(AppAnimation.quick, value: isHovering)
    }
}

/// A toolbar icon-only button style that renders reliably in off-screen captures.
struct ToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.body)
            .foregroundStyle(.primary)
            .padding(AppSpacing.mini)
            .background(
                configuration.isPressed && isEnabled
                    ? Color.primary.opacity(0.12)
                    : isHovering && isEnabled ? Color.primary.opacity(0.08) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: isHovering)
            .animation(AppAnimation.quick, value: configuration.isPressed)
    }
}

// MARK: - Icon buttons

/// Icon-only button with explicit hover + press feedback.
/// Use in place of `.buttonStyle(.borderless)` for toolbar icons, row actions,
/// and dismiss buttons so hit areas are discoverable on hover.
/// Sizing for `IconButtonStyle`: total height is frame + padding so each
/// variant pairs with its neighbors — regular (28pt) matches
/// `RefreshControl`, row is glyph-sized so `Table` rows keep text height
/// instead of being stretched by their action buttons.
enum IconButtonSize: Sendable {
    case regular
    case row

    /// Fixed inner frame; nil sizes to the glyph.
    var minSide: CGFloat? {
        switch self {
        case .regular: return 20
        case .row: return nil
        }
    }

    var padding: CGFloat {
        switch self {
        case .regular: return AppSpacing.xSmall
        case .row: return AppSpacing.xxSmall
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var isDestructive = false
    var size: IconButtonSize = .regular
    var weight: Font.Weight = .medium
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: weight))
            .imageScale(.medium)
            .frame(minWidth: size.minSide ?? 0, minHeight: size.minSide ?? 0)
            .padding(size.padding)
            .background(
                hoverBackground(isPressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
            )
            .brightness(configuration.isPressed && isEnabled ? -0.06 : 0)
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .animation(AppAnimation.quick, value: isHovering)
    }

    private func hoverBackground(isPressed: Bool) -> Color {
        guard isEnabled else { return Color.clear }
        if isPressed {
            return isDestructive ? Color.red.opacity(0.16) : Color.primary.opacity(0.12)
        }
        if isHovering {
            return isDestructive ? Color.red.opacity(0.1) : AppColor.iconHoverBackground
        }
        return Color.clear
    }
}

// MARK: - Toolbar capsule chrome

extension View {
    /// Persistent toolbar pill chrome (the `RefreshControl` look): secondary
    /// fill + hairline separator border. Hover/press wash comes from the
    /// control's own style layered on top of this.
    func toolbarCapsule() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }
}

// MARK: - Hover background for custom rows

private struct HoverBackgroundModifier: ViewModifier {
    var cornerRadius: CGFloat = AppRadius.small
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovering ? AppColor.hoverBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: isHovering)
    }
}

extension View {
    /// Subtle hover wash for custom tappable rows/cards that don't use a
    /// `ButtonStyle` (e.g. `onTapGesture` rows, section headers).
    func hoverBackground(
        cornerRadius: CGFloat = AppRadius.small
    ) -> some View {
        modifier(HoverBackgroundModifier(cornerRadius: cornerRadius))
    }
}
