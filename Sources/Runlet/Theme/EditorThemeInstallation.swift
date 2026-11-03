import AppKit
import Plume

// DEBUG access to the internal switch
import SwiftUI

/// Installs Runlet's chrome into Plume's `EditorTheme` seam: the one-time,
/// launch-time assignment of every token the editor base library reads.
/// Colors are dynamic (light/dark adaptive via the Palette), so a single
/// install at launch keeps both appearances correct; nothing re-reads these
/// after startup.
enum EditorThemeInstallation {
    static func install() {
        // Semantic colors
        EditorTheme.accent = .accentColor
        EditorTheme.success = AppColor.success
        EditorTheme.error = AppColor.error
        EditorTheme.warning = AppColor.warning
        EditorTheme.textPrimary = AppColor.editorTextPrimary
        EditorTheme.textSecondary = .secondary
        EditorTheme.tertiaryText = Color(nsColor: .tertiaryLabelColor)
        EditorTheme.border = AppColor.subtleBorder
        EditorTheme.borderStrong = AppColor.fieldHoverBorder
        EditorTheme.destructiveBorder = AppColor.error.opacity(0.55)
        EditorTheme.controlBackground = AppColor.controlBackground
        EditorTheme.fieldBackground = AppColor.fieldFocusBackground
        EditorTheme.subtleBackground = AppColor.subtleBackground
        EditorTheme.tabHoverBackground = AppColor.hoverBackground
        EditorTheme.tabActiveBackground = AppColor.selectionBackground
        EditorTheme.popupShadow = AppColor.subtleBorder

        // AppKit fills
        EditorTheme.textPrimaryNS = AppColor.editorTextPrimaryNS
        EditorTheme.codeBackgroundNS = NSColor(AppColor.codeBackground)

        // Syntax palette: map Runlet's Lua-oriented token colors onto
        // Plume's five slots. The walks color by ROLE, so builtin/type
        // tokens share the keyword slot without losing their distinctness
        // inside Runlet's own viewers.
        EditorTheme.syntaxKey = AppColor.syntaxType
        EditorTheme.syntaxString = AppColor.syntaxString
        EditorTheme.syntaxNumber = AppColor.syntaxNumber
        EditorTheme.syntaxKeyword = AppColor.syntaxKey
        EditorTheme.syntaxPlain = AppColor.syntaxPunctuation

        // Fonts
        EditorTheme.fontSmall = .system(size: 12)
        EditorTheme.fontMonoSubheadline = AppFont.monoSubheadline
        EditorTheme.fontMonoBody = AppFont.monoBody
        EditorTheme.fontMonoURLBar = AppFont.monoSubheadline
        EditorTheme.fontMonoCaption = AppFont.monoCaption2
        EditorTheme.fontIconCompact = .system(size: 12)

        // Metrics
        EditorTheme.spaceXSmall = AppSpacing.xSmall
        EditorTheme.spaceSmall = AppSpacing.small
        EditorTheme.spaceCompact = AppSpacing.mini
        EditorTheme.spaceMedium = AppSpacing.medium
        EditorTheme.radiusSmall = AppRadius.small
        EditorTheme.radiusMedium = AppRadius.medium
        EditorTheme.lineField = AppBorderWidth.regular
        EditorTheme.lineFocusedField = AppBorderWidth.focused
        EditorTheme.toggleControlSize = 26
        EditorTheme.opacityDisabled = 0.45
        EditorTheme.motionQuick = AppAnimation.quick
    }
}
