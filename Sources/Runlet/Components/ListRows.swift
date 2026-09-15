import AppKit
import SwiftUI

// MARK: - Double Click Handler

/// A SwiftUI wrapper for detecting double-clicks on views, backed by AppKit.
///
/// The overlay view covers its entire container, which occludes SwiftUI's
/// `onHover` tracking underneath — so it also reports hover via an
/// `NSTrackingArea`. Owners drive hover-driven chrome (e.g. row wash) from
/// the `onHover` callback instead of `.onHover`, which would never fire.
struct DoubleClickHandler: NSViewRepresentable {
    let onDoubleClick: () -> Void
    var onHover: ((Bool) -> Void)?

    func makeNSView(context: Context) -> DoubleClickView {
        let view = DoubleClickView()
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: DoubleClickView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
        nsView.onHover = onHover
    }
}

class DoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }
}

// MARK: - Copyable Cells

struct CopyableCellModifier: ViewModifier {
    let cellValue: String
    let rowValue: String

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Copy Cell") {
                copyToPasteboard(cellValue)
            }
            Button("Copy Row") {
                copyToPasteboard(rowValue)
            }
        }
    }
}

extension View {
    func copyableCell(_ cellValue: String, row: String) -> some View {
        modifier(CopyableCellModifier(cellValue: cellValue, rowValue: row))
    }
}

// MARK: - Full-Width List Row

private struct ListRowIsSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the enclosing full-width list row is painted with the emphasized
    /// selection highlight, so row content can flip to legible on-selection colors.
    var listRowIsSelected: Bool {
        get { self[ListRowIsSelectedKey.self] }
        set { self[ListRowIsSelectedKey.self] = newValue }
    }
}

extension View {
    /// Draws the chrome of a full-width list row: the selection highlight and
    /// a 1pt bottom separator, both spanning the enclosing scroll container
    /// edge to edge (connecting to the split-view dividers on both sides).
    ///
    /// Neither can be left to the system: the row separator's leading inset
    /// follows row indentation and `listRowInsets` can't remove it on macOS,
    /// and the selection highlight is inset from the row edges. So we hide the
    /// system separator and paint both ourselves, sized to the container's
    /// width with `containerRelativeFrame`. This assumes the row fills the
    /// container's width, which plain `LazyVStack` rows do (namespace tree
    /// depth is drawn as internal padding).
    ///
    /// The highlight uses `selectedContentBackgroundColor`, the same emphasized
    /// selection color the system paints list rows with: it follows the accent
    /// color and stays vivid in dark mode, unlike `selectedControlColor`, which
    /// is a control-face color that resolves to a desaturated slate blue there.
    /// That fill is strong in both appearances, so the selected state is also
    /// published through the `listRowIsSelected` environment value, letting row
    /// content flip to on-selection foreground colors (white) like native lists.
    ///
    /// Hover is tracked internally and paints a subtle wash when the row is
    /// neither selected nor pressed, so `LazyVStack` rows match the hover
    /// feedback of `RefreshControl` and icon buttons without callers managing
    /// hover state. Dense data rows (Profiler, cluster nodes) use the
    /// translucent `AppColor/selectionBackground` instead — see those views.
    ///
    /// The separator is drawn as an overlay, except on the selected row where
    /// it is hidden: the selection highlight already marks the row boundary,
    /// and a line painted over the opaque selection color would read much
    /// heavier than the neighboring separators. Hiding it matches native
    /// table behavior, where no separator is drawn at the selection edge.
    func fullWidthListRow(selected: Bool) -> some View {
        modifier(FullWidthListRowModifier(selected: selected))
    }
}

private struct FullWidthListRowModifier: ViewModifier {
    let selected: Bool
    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .listRowSeparator(.hidden)
            .environment(\.listRowIsSelected, selected)
            .background {
                ZStack {
                    Color.primary.opacity(isHovering && !selected ? 0.06 : 0)
                    // Dim to the unemphasized (gray) selection when the window
                    // loses key status, matching native list blur behavior.
                    Color(
                        nsColor: controlActiveState == .inactive
                            ? .unemphasizedSelectedContentBackgroundColor
                            : .selectedContentBackgroundColor
                    )
                    .opacity(selected ? 1 : 0)
                }
                .containerRelativeFrame(.horizontal)
            }
            .overlay(alignment: .bottom) {
                Color(nsColor: .separatorColor)
                    .frame(height: 1)
                    .containerRelativeFrame(.horizontal)
                    .opacity(selected ? 0 : 1)
            }
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: isHovering)
    }
}

extension View {
    /// Hover wash for native (`List`) sidebar rows, painted in the
    /// row-background layer with the same inset rounded-rectangle geometry
    /// as the system sidebar selection — same shape, different fill.
    ///
    /// When `active` is false the wash is fully transparent, so the system
    /// selection highlight underneath keeps rendering untouched.
    func sidebarHoverWash(active: Bool) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(active ? AppColor.hoverBackground : Color.clear)
                .padding(.horizontal, AppSize.sidebarSelectionInset)
        )
    }
}

// MARK: - Inline Text Field

struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.delegate = context.coordinator
        textField.focusRingType = .default
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Claim first responder exactly once per cell lifetime. Re-claiming
        // on every update would yank focus back after an intentional blur
        // (click-away), making it impossible to leave the cell.
        let coordinator = context.coordinator
        if !coordinator.didClaimFocus, let window = nsView.window {
            window.makeFirstResponder(nsView)
            if window.firstResponder == nsView {
                coordinator.didClaimFocus = true
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: InlineTextField
        private var isCancelling = false
        private var isSubmitting = false
        var didClaimFocus = false

        init(_ parent: InlineTextField) {
            self.parent = parent
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                isSubmitting = true
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                isCancelling = true
                parent.onCancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            defer {
                isCancelling = false
                isSubmitting = false
            }
            guard !isCancelling, !isSubmitting else { return }
            parent.onSubmit()
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }
    }
}
