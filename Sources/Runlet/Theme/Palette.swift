import AppKit

/// One side (light or dark) of a color theme: a complete set of surface
/// colors, wash strengths, and syntax hues.
///
/// `AppColor` resolves each semantic token by reading the slot from the
/// palette matching the active appearance, so introducing an additional theme
/// means adding another `Palette` instance and pointing the per-side lookup
/// at it — no token or call site changes. Themes organize light and dark
/// independently: a theme may declare a palette for either side.
///
/// Washes (translucent fills for hover/press/track/banner states) are stored
/// as alpha strengths over shared dynamic bases (`labelColor`, `systemRed`,
/// `systemOrange`) rather than resolved colors: the bases must keep
/// re-resolving per appearance, so `AppColor` applies the alpha at resolution
/// time. Everything else is a concrete `NSColor`.
///
/// Evolution roadmap
/// =================
/// This type is step one of the theming refactor: palettes are data, tokens
/// are lookups. The remaining steps, to take when a second theme actually
/// lands:
///
/// - Theme model: a `Theme` bundles an id/name with optional per-side
///   palettes (`light: Palette?`, `dark: Palette?`); a nil side falls back to
///   the system colors that `systemLight` wraps today. Appearance
///   (system/light/dark, see `AppAppearance`) and theme stay independent
///   axes — the active side picks that side's theme palette.
/// - Settings: `AppSettings` gains per-side theme selection alongside the
///   existing `appearance` field; the View menu and the settings pane expose it.
/// - Distribution: `AppColor`'s private `paletteColor`/`paletteNSColor`/
///   `paletteWash` helpers are the only place hardwiring `systemLight` and
///   `neutralDark` — they are the seam to redirect at a theme registry. The
///   switch itself needs a re-resolution channel; the candidates, in rough
///   order of preference:
///   1. Register a custom `NSAppearance` per active light/dark pair and let
///      the dynamic providers identify the theme from the appearance they
///      receive. Reuses the machinery that already re-resolves every token
///      on light/dark switches; zero call-site changes. Cost: obscure AppKit.
///   2. Move token reads behind an observable theme object injected in the
///      environment. SwiftUI-native, but every view gains a dependency.
///   3. Rebuild window content on switch. Trivial, but resets scroll,
///      focus, and other transient state.
///
/// Adding a palette slot later is additive: extend this struct, fill both
/// existing instances, and add one token line in `AppColor`.
struct Palette {
    // MARK: Surfaces

    /// Main window/content background.
    let windowBackground: NSColor
    /// Secondary surfaces: sidebars, headers, tables, fields.
    let secondaryBackground: NSColor
    /// Raised pill/track surfaces: segmented pickers, refresh pills,
    /// dropdown labels, secondary buttons. A step above `secondaryBackground`
    /// so unselected segments stay legible instead of sinking into the track.
    let pillBackground: NSColor
    /// Code and monospace text surfaces.
    let codeBackground: NSColor
    /// Sidebar base.
    let sidebarBackground: NSColor

    // MARK: Washes (alpha strength over a shared base)

    /// Light fill for badges and secondary chrome (over `labelColor`).
    let subtleBackground: Double
    /// Track background for distribution bars and similar meters (over `labelColor`).
    let trackBackground: Double
    /// Hairline stroke for custom control chrome, button borders, panel
    /// outlines (over `labelColor`).
    let subtleBorder: Double
    /// Tint layered over the sidebar's opaque base (over `labelColor`). Use
    /// `0` when the sidebar already reads distinct from the content area.
    let sidebarTint: Double
    /// Hover wash for custom rows (over `labelColor`).
    let hoverBackground: Double
    /// Hover wash for icon buttons — stronger than `hoverBackground` so small
    /// hit areas read clearly (over `labelColor`).
    let iconHoverBackground: Double
    /// Pressed/selected fill that must stay clearly stronger than hover:
    /// toolbar button press, segmented toggle selection, unemphasized rows
    /// (over `labelColor`).
    let controlFillBackground: Double
    /// Shell output block background (over `labelColor`).
    let shellOutputBackground: Double
    /// Wash behind destructive hover/press feedback, delete buttons
    /// (over `systemRed`).
    let destructiveBackground: Double
    /// Error banner fill (over `systemRed`).
    let errorBannerBackground: Double
    /// Warning banner fill (over `systemOrange`).
    let warningBannerBackground: Double

    // MARK: Syntax highlighting

    /// Keywords: `local`, `function`, `return`, `if`
    let syntaxKey: NSColor
    /// Built-in functions & API members: `pairs`, `redis.call`
    let syntaxBuiltin: NSColor
    /// String literals
    let syntaxString: NSColor
    /// Numeric literals
    let syntaxNumber: NSColor
    /// Boolean literals & named constants: `true`, `LOG_DEBUG`
    let syntaxBool: NSColor
    /// Type-like tokens & JSON object keys
    let syntaxType: NSColor
}

extension Palette {
    /// The light side in use today: system colors with the airy wash
    /// defaults and lower-luminance syntax hues.
    static let systemLight = Palette(
        windowBackground: .windowBackgroundColor,
        secondaryBackground: .controlBackgroundColor,
        // One visible step above the white content surface — approximates the
        // hierarchical `.background.secondary` fill pills had before theming.
        // Tune here if the step ever reads too subtle or too strong.
        pillBackground: NSColor(srgbRed: 242.0 / 255.0, green: 242.0 / 255.0, blue: 242.0 / 255.0, alpha: 1),
        codeBackground: .textBackgroundColor,
        sidebarBackground: .windowBackgroundColor,
        subtleBackground: 0.08,
        trackBackground: 0.12,
        subtleBorder: 0.12,
        sidebarTint: 0.05,
        hoverBackground: 0.06,
        iconHoverBackground: 0.08,
        controlFillBackground: 0.12,
        shellOutputBackground: 0.08,
        destructiveBackground: 0.12,
        errorBannerBackground: 0.12,
        warningBannerBackground: 0.12,
        syntaxKey: hsb(0.750, 0.50, 0.55),
        syntaxBuiltin: hsb(0.514, 0.65, 0.45),
        syntaxString: hsb(0.375, 0.55, 0.42),
        syntaxNumber: hsb(0.078, 0.70, 0.65),
        syntaxBool: hsb(0.931, 0.50, 0.60),
        syntaxType: hsb(0.597, 0.60, 0.55)
    )

    /// The dark side in use today: the flat neutral set — #262626 main,
    /// #212121 secondary, #2E2E2E pills — with stronger washes for legibility
    /// and lifted syntax hues.
    static let neutralDark = Palette(
        windowBackground: NSColor(srgbRed: 38.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0, alpha: 1),
        secondaryBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        pillBackground: NSColor(srgbRed: 46.0 / 255.0, green: 46.0 / 255.0, blue: 46.0 / 255.0, alpha: 1),
        codeBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        sidebarBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        subtleBackground: 0.12,
        trackBackground: 0.18,
        subtleBorder: 0.18,
        sidebarTint: 0.0,
        hoverBackground: 0.10,
        iconHoverBackground: 0.13,
        controlFillBackground: 0.16,
        shellOutputBackground: 0.12,
        destructiveBackground: 0.20,
        errorBannerBackground: 0.18,
        warningBannerBackground: 0.18,
        syntaxKey: hsb(0.750, 0.40, 0.82),
        syntaxBuiltin: hsb(0.514, 0.50, 0.78),
        syntaxString: hsb(0.375, 0.42, 0.75),
        syntaxNumber: hsb(0.078, 0.58, 0.88),
        syntaxBool: hsb(0.931, 0.38, 0.82),
        syntaxType: hsb(0.597, 0.48, 0.82)
    )

    private static func hsb(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }
}
