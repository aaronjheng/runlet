import SwiftUI

/// Semantic color tokens used across the app.
///
/// Prefer these over raw `.red`/`.green`/`.blue` so the inventory generator and
/// future theming always render consistent, readable colors.
///
/// Washes (translucent fills for hover/press/track states) resolve through
/// `NSColor` dynamic providers so each appearance gets a tuned opacity: a wash
/// that reads clearly on a white surface nearly disappears on a dark one, so
/// dark mode uses stronger alphas while light mode keeps the airy defaults.
/// Resolving per appearance — instead of checking `NSApp.effectiveAppearance`
/// at view-build time — keeps every surface correct when the user switches
/// styles mid-session, including per-window overrides.
enum AppColor {
    // MARK: - Status

    static let success: Color = .green
    static let error: Color = .red
    static let warning: Color = .orange
    static let info: Color = .blue

    // MARK: - Backgrounds

    static let codeBackground: Color = Color(nsColor: .textBackgroundColor)
    static let controlBackground: Color = Color(nsColor: .controlBackgroundColor)

    /// Light fill for badges and secondary chrome.
    static let subtleBackground = adaptiveColor(.labelColor, light: 0.08, dark: 0.12)

    /// Standard semi-transparent badge background for a given accent color.
    static func badgeBackground(_ color: Color) -> Color {
        color.opacity(0.12)
    }

    /// Track background for distribution bars and similar meters.
    static let trackBackground = adaptiveColor(.labelColor, light: 0.12, dark: 0.18)

    /// Hairline stroke for custom control chrome (button borders, panel outlines).
    static let subtleBorder = adaptiveColor(.labelColor, light: 0.12, dark: 0.18)

    /// Tint layered over the sidebar's opaque base so it stays visually
    /// distinct from the content area; dark mode needs slightly more contrast.
    static let sidebarTint = adaptiveColor(.labelColor, light: 0.05, dark: 0.07)

    /// Highlight background for selected rows/items in lists and tables.
    /// Subtle variant for dense data rows (Profiler, cluster nodes) where the
    /// emphasized system selection would overwhelm the content.
    static let selectionBackground: Color = Color.accentColor.opacity(0.14)

    // MARK: - Interactive washes

    /// Hover wash for custom rows. Matches `RefreshControl` so hover feels
    /// identical across toolbars, lists, and icon buttons.
    static let hoverBackground = adaptiveColor(.labelColor, light: 0.06, dark: 0.10)

    /// Hover wash for icon buttons. Slightly stronger than rows so small
    /// hit areas read clearly.
    static let iconHoverBackground = adaptiveColor(.labelColor, light: 0.08, dark: 0.13)

    /// Pressed/selected fill that must stay clearly stronger than hover
    /// (toolbar button press, segmented toggle selection, unemphasized rows).
    static let controlFillBackground = adaptiveColor(.labelColor, light: 0.12, dark: 0.16)

    /// Wash behind destructive hover/press feedback (delete buttons).
    static let destructiveBackground = adaptiveColor(.systemRed, light: 0.12, dark: 0.20)

    // MARK: - Banners

    /// Error banner fill; dark mode needs a stronger wash to stay legible.
    static let errorBannerBackground = adaptiveColor(.systemRed, light: 0.12, dark: 0.18)

    /// Warning banner fill; dark mode needs a stronger wash to stay legible.
    static let warningBannerBackground = adaptiveColor(.systemOrange, light: 0.12, dark: 0.18)

    // MARK: - Selection content

    /// Foreground for primary text drawn on the emphasized selection highlight.
    static let onSelection: Color = .white

    /// Foreground for secondary text (badges, metadata) on the selection highlight.
    static let onSelectionSecondary: Color = .white.opacity(0.8)

    /// Translucent badge background that stays legible on the selection highlight.
    static let selectionBadgeBackground: Color = .white.opacity(0.18)

    // MARK: - Redis type chart colors

    static let chartString: Color = .blue
    static let chartList: Color = .green
    static let chartHash: Color = .orange
    static let chartSet: Color = .purple
    static let chartZSet: Color = .pink

    // MARK: - TTL buckets

    static let ttlExpired: Color = .red
    static let ttlShort: Color = .orange
    static let ttlMedium: Color = .yellow
    static let ttlLong: Color = .blue
    static let ttlDistant: Color = .green

    // MARK: - Shell

    static let shellPrompt: Color = .secondary
    static let shellCommand: Color = .primary
    static let shellSuccess: Color = .secondary
    static let shellError: Color = .red
    static let shellOutputBackground = adaptiveColor(.labelColor, light: 0.08, dark: 0.12)

    // MARK: - Syntax highlighting

    /// Resolves `base` with `light` alpha in light appearance and `dark` alpha
    /// in dark appearance, re-evaluating whenever the surrounding environment
    /// switches appearance.
    private static func adaptiveColor(_ base: NSColor, light: Double, dark: Double) -> Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return base.withAlphaComponent(CGFloat(isDark ? dark : light))
                }))
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                }))
    }

    private static func hsb(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    /// Keywords: `local`, `function`, `return`, `if`
    static let syntaxKey = dynamicColor(
        light: hsb(0.750, 0.50, 0.55),
        dark: hsb(0.750, 0.40, 0.82)
    )

    /// Built-in functions & API members: `pairs`, `redis.call`
    static let syntaxBuiltin = dynamicColor(
        light: hsb(0.514, 0.65, 0.45),
        dark: hsb(0.514, 0.50, 0.78)
    )

    /// String literals
    static let syntaxString = dynamicColor(
        light: hsb(0.375, 0.55, 0.42),
        dark: hsb(0.375, 0.42, 0.75)
    )

    /// Numeric literals
    static let syntaxNumber = dynamicColor(
        light: hsb(0.078, 0.70, 0.65),
        dark: hsb(0.078, 0.58, 0.88)
    )

    /// Boolean literals & named constants: `true`, `LOG_DEBUG`
    static let syntaxBool = dynamicColor(
        light: hsb(0.931, 0.50, 0.60),
        dark: hsb(0.931, 0.38, 0.82)
    )

    /// Named constants — same visual group as booleans
    static let syntaxConstant = syntaxBool

    /// Type-like tokens & JSON object keys
    static let syntaxType = dynamicColor(
        light: hsb(0.597, 0.60, 0.55),
        dark: hsb(0.597, 0.48, 0.82)
    )

    /// Null / nil — deliberately muted
    static let syntaxNull = Color(nsColor: .secondaryLabelColor)

    /// Punctuation — inherits system secondary
    static let syntaxPunctuation: Color = .secondary
}
