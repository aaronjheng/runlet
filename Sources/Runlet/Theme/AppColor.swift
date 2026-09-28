import SwiftUI

/// Semantic color tokens used across the app.
///
/// Prefer these over raw `.red`/`.green`/`.blue` so the inventory generator and
/// future theming always render consistent, readable colors.
///
/// Every appearance-dependent token resolves from a `Palette`: the palette
/// matching the active appearance supplies the slot value at draw time, so
/// switching styles mid-session — including per-window overrides — keeps every
/// surface correct. Introducing an additional theme means adding a `Palette`
/// instance; no token or call site changes.
///
/// Washes (translucent fills for hover/press/track states) stay alpha
/// strengths inside the palette and are applied over shared dynamic bases
/// (`labelColor`, `systemRed`, `systemOrange`) at resolution time: the bases
/// must keep re-resolving per appearance, while the wash strength is a
/// per-palette decision.
///
/// The theming roadmap — how palettes become selectable themes — lives in
/// `Palette.swift`. In short: this enum stays the only token surface; when a
/// theme registry arrives, only the private `paletteColor`/`paletteNSColor`/
/// `paletteWash` helpers below change.
enum AppColor {
    // MARK: - Status

    static let success: Color = .green
    static let error: Color = .red
    static let warning: Color = .orange
    static let info: Color = .blue

    // MARK: - Backgrounds

    /// Main window/content background. The dark palette uses the custom #262626.
    static let windowBackground = paletteColor(\.windowBackground)

    /// AppKit counterpart of `windowBackground` for `NSWindow.backgroundColor`
    /// and other `NSView`-level surfaces.
    static let windowBackgroundNS = paletteNSColor(\.windowBackground)

    /// Secondary surfaces (sidebars, headers, tables, fields). The dark
    /// palette uses the custom #212121.
    static let secondaryBackground = paletteColor(\.secondaryBackground)

    /// AppKit counterpart of `secondaryBackground` for `NSTableView` and
    /// scroll view backgrounds.
    static let secondaryBackgroundNS = paletteNSColor(\.secondaryBackground)

    /// Sidebar base. Tracks the window color in light mode (plus
    /// `sidebarTint` below); the dark palette pins it to the flat #212121.
    static let sidebarBackground = paletteColor(\.sidebarBackground)

    /// Raised pill/track surfaces (segmented pickers, refresh pills, dropdown
    /// labels, secondary buttons): a step above the secondary base so
    /// unselected segments stay legible instead of sinking into the track.
    static let pillBackground = paletteColor(\.pillBackground)

    static let codeBackground = paletteColor(\.codeBackground)
    static let controlBackground: Color = secondaryBackground

    /// Light fill for badges and secondary chrome.
    static let subtleBackground = paletteWash(\.subtleBackground)

    /// Standard semi-transparent badge background for a given accent color.
    static func badgeBackground(_ color: Color) -> Color {
        color.opacity(0.12)
    }

    /// Track background for distribution bars and similar meters.
    static let trackBackground = paletteWash(\.trackBackground)

    /// Hairline stroke for custom control chrome (button borders, panel outlines).
    static let subtleBorder = paletteWash(\.subtleBorder)

    /// Tint layered over the sidebar's opaque base so it stays visually
    /// distinct from the content area in light mode. The dark palette pins
    /// the sidebar to the flat base instead, so no tint is applied.
    static let sidebarTint = paletteWash(\.sidebarTint)

    /// Highlight background for selected rows/items in lists and tables.
    /// Subtle variant for dense data rows (Profiler, cluster nodes) where the
    /// emphasized system selection would overwhelm the content.
    static let selectionBackground: Color = Color.accentColor.opacity(0.14)

    // MARK: - Interactive washes

    /// Hover wash for custom rows. Matches `RefreshControl` so hover feels
    /// identical across toolbars, lists, and icon buttons.
    static let hoverBackground = paletteWash(\.hoverBackground)

    /// Hover wash for icon buttons. Slightly stronger than rows so small
    /// hit areas read clearly.
    static let iconHoverBackground = paletteWash(\.iconHoverBackground)

    /// Pressed/selected fill that must stay clearly stronger than hover
    /// (toolbar button press, segmented toggle selection, unemphasized rows).
    static let controlFillBackground = paletteWash(\.controlFillBackground)

    /// Wash behind destructive hover/press feedback (delete buttons).
    static let destructiveBackground = paletteWash(\.destructiveBackground, base: .systemRed)

    // MARK: - Banners

    /// Error banner fill; the dark palette needs a stronger wash to stay legible.
    static let errorBannerBackground = paletteWash(\.errorBannerBackground, base: .systemRed)

    /// Warning banner fill; the dark palette needs a stronger wash to stay legible.
    static let warningBannerBackground = paletteWash(\.warningBannerBackground, base: .systemOrange)

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
    static let shellOutputBackground = paletteWash(\.shellOutputBackground)

    // MARK: - Syntax highlighting

    /// Keywords: `local`, `function`, `return`, `if`
    static let syntaxKey = paletteColor(\.syntaxKey)

    /// Built-in functions & API members: `pairs`, `redis.call`
    static let syntaxBuiltin = paletteColor(\.syntaxBuiltin)

    /// String literals
    static let syntaxString = paletteColor(\.syntaxString)

    /// Numeric literals
    static let syntaxNumber = paletteColor(\.syntaxNumber)

    /// Boolean literals & named constants: `true`, `LOG_DEBUG`
    static let syntaxBool = paletteColor(\.syntaxBool)

    /// Named constants — same visual group as booleans
    static let syntaxConstant = syntaxBool

    /// Type-like tokens & JSON object keys
    static let syntaxType = paletteColor(\.syntaxType)

    /// Null / nil — deliberately muted
    static let syntaxNull = Color(nsColor: .secondaryLabelColor)

    /// Punctuation — inherits system secondary
    static let syntaxPunctuation: Color = .secondary

    // MARK: - Palette resolution

    // These three helpers are the seam from step one of the theming refactor:
    // the only place that hardwires `systemLight`/`neutralDark`. Redirecting
    // them at a theme registry is the entire step-two change on this side.

    /// Color for `slot`, read from the palette matching the active appearance.
    private static func paletteColor(_ slot: KeyPath<Palette, NSColor>) -> Color {
        dynamicColor(
            light: Palette.systemLight[keyPath: slot],
            dark: Palette.neutralDark[keyPath: slot])
    }

    /// AppKit counterpart of `paletteColor` for surfaces that take `NSColor`
    /// directly (`NSWindow.backgroundColor`, `NSTableView`).
    private static func paletteNSColor(_ slot: KeyPath<Palette, NSColor>) -> NSColor {
        dynamicNSColor(
            light: Palette.systemLight[keyPath: slot],
            dark: Palette.neutralDark[keyPath: slot])
    }

    /// Translucent fill for `slot`'s alpha strength over `base`, re-resolved
    /// whenever the surrounding environment switches appearance.
    private static func paletteWash(
        _ slot: KeyPath<Palette, Double>,
        base: NSColor = .labelColor
    ) -> Color {
        adaptiveColor(
            base,
            light: Palette.systemLight[keyPath: slot],
            dark: Palette.neutralDark[keyPath: slot])
    }

    /// `NSColor` twin of `dynamicColor` for AppKit surfaces that take
    /// `NSColor` directly (`NSWindow.backgroundColor`, `NSTableView`).
    private static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(
            name: nil,
            dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
    }

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
}
