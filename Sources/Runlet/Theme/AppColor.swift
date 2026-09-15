import SwiftUI

/// Semantic color tokens used across the app.
///
/// Prefer these over raw `.red`/`.green`/`.blue` so the inventory generator and
/// future theming always render consistent, readable colors.
enum AppColor {
    // MARK: - Status

    static let success: Color = .green
    static let error: Color = .red
    static let warning: Color = .orange
    static let info: Color = .blue

    // MARK: - Backgrounds

    static let codeBackground: Color = Color(nsColor: .textBackgroundColor)
    static let controlBackground: Color = Color(nsColor: .controlBackgroundColor)
    static let subtleBackground: Color = Color.secondary.opacity(0.12)

    /// Standard semi-transparent badge background for a given accent color.
    static func badgeBackground(_ color: Color) -> Color {
        color.opacity(0.12)
    }

    /// Track background for distribution bars and similar meters.
    static let trackBackground: Color = Color.primary.opacity(0.12)

    /// Highlight background for selected rows/items in lists and tables.
    /// Subtle variant for dense data rows (Profiler, cluster nodes) where the
    /// emphasized system selection would overwhelm the content.
    static let selectionBackground: Color = Color.accentColor.opacity(0.14)

    /// Hover wash for custom rows. Matches `RefreshControl` so hover feels
    /// identical across toolbars, lists, and icon buttons.
    static let hoverBackground: Color = Color.primary.opacity(0.06)

    /// Hover wash for icon buttons. Slightly stronger than rows so small
    /// hit areas read clearly.
    static let iconHoverBackground: Color = Color.primary.opacity(0.08)

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
    static let shellOutputBackground: Color = Color.secondary.opacity(0.1)

    // MARK: - Syntax highlighting

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
