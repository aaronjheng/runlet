import AppKit
import SwiftUI

// MARK: - Sidebar Background

extension View {
    /// Replaces the system presentation material behind sheets and popovers
    /// with the app's opaque window background. The default material is
    /// translucent and picks up the wallpaper's tint, so in dark mode it reads
    /// brownish next to the flat neutral surfaces everywhere else.
    func presentationSurface() -> some View {
        presentationBackground(AppColor.windowBackground)
    }

    /// Gives a `.listStyle(.sidebar)` list a flat, opaque background with a slight tint
    /// so the sidebar stays visually distinct from the content area.
    ///
    /// Outside a navigation container (e.g. inside a plain `HSplitView`), a sidebar-styled
    /// list is backed by an `NSVisualEffectView` that blends with whatever is behind the
    /// window, so the sidebar turns translucent in windowed mode and only looks right in
    /// fullscreen. Hiding the list's scroll background and painting an opaque color instead
    /// keeps the sidebar flat in every window state; the light tint on top reproduces the
    /// subtle sidebar/content contrast the system material used to provide.
    func flatSidebarBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(AppColor.sidebarTint)
            .background(AppColor.sidebarBackground)
    }
}

struct PanelFooterBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            content
        }
        .font(.caption)
        .controlSize(.small)
        .imageScale(.small)
        .padding(.horizontal, AppSpacing.small)
        .frame(minHeight: AppSize.footerHeight)
        .frame(maxWidth: .infinity)
        // Frame chrome, like the titlebar: the status bar reads as part of the
        // window frame, not as another content surface.
        .background(AppColor.windowBackground)
    }
}

/// Standard layout for panel toolbars/headers (Keys, Shell, Profiler, Slow Log, Analysis, Server Info).
/// Enforces a consistent minimum height while still letting a header grow to fit taller content.
struct PanelToolbarModifier: ViewModifier {
    var horizontalPadding: CGFloat = AppSpacing.large

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: AppSize.toolbarHeight)
    }
}

extension View {
    /// Applies the shared panel toolbar layout: standard horizontal padding plus a unified minimum height.
    func panelToolbar(horizontalPadding: CGFloat = AppSpacing.large) -> some View {
        modifier(PanelToolbarModifier(horizontalPadding: horizontalPadding))
    }
}

/// "1 library" vs "3 libraries" without hand-rolled ternaries at call sites.
func pluralizedCount(_ count: Int, singular: String, plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
}

struct StatusFooterView: View {
    let countText: String
    var sizeText: String?

    init(countText: String, sizeText: String? = nil) {
        self.countText = countText
        self.sizeText = sizeText
    }

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text(countText)
            if let sizeText {
                Text("\u{00B7}")
                Text(sizeText)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
