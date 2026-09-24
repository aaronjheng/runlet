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
                    isHovering && !selected ? AppColor.hoverBackground : Color.clear
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

/// Inline editor for editable table cells (List values, Hash values, ZSet
/// scores).
///
/// The editor is a real AppKit field — standard bezel, 2 pt focus border,
/// sized to the cell it edits — exactly like native table inline editing. It
/// lives in the enclosing `NSScrollView`'s clip view rather than in the cell:
/// SwiftUI's table row view clips its content to the row's height, so a field
/// inside the cell either fills the row (and `Table`, which sizes rows to
/// their tallest cell, stretches it) or stays small enough to leave no room
/// for its focus border. A clip-view subview shares the
/// table's coordinate space, so it scrolls with its row for free.
///
/// Attach it as an overlay of the text the cell shows while idle, so that text
/// — and with it the row height — stays in place underneath:
///
/// ```swift
/// Text(row.value)
///     .font(AppFont.dataCell)
///     .lineLimit(2)
///     .opacity(isEditing ? 0 : 1)
///     .overlay {
///         if isEditing {
///             InlineTextField(original: row.value, text: $editValue, onSubmit: save, onCancel: cancel)
///         }
///     }
/// ```
struct InlineTextField: NSViewRepresentable {
    /// Value the cell displays. Submitting it unchanged closes the editor
    /// through `onCancel` instead of saving, so a no-op overwrite never costs
    /// a write, a production confirmation, and a full key reload.
    let original: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> InlineTextFieldAnchorView {
        let anchor = InlineTextFieldAnchorView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.attach(to: anchor)
        anchor.onMoveToWindow = { coordinator.place() }
        return anchor
    }

    func updateNSView(_ nsView: InlineTextFieldAnchorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(text: text)
    }

    static func dismantleNSView(_ nsView: InlineTextFieldAnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Zero-size view marking the cell being edited. It only reports entering a
    /// window — the first moment the enclosing table is reachable — so the
    /// field can be placed and focused.
    final class InlineTextFieldAnchorView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            onMoveToWindow?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        /// The representable's current inputs. Refreshed on every update so the
        /// no-op check compares against the value the cell displays *now*,
        /// which advances when a save's reload brings the written value back.
        var parent: InlineTextField
        private let field = NSTextField()
        private weak var anchorView: NSView?
        private weak var clipView: NSClipView?
        private weak var tableView: NSTableView?
        private var didClaimFocus = false
        /// True while the editor is being torn down. Removing the field ends its
        /// editing session, and the end-editing notification that follows must
        /// not submit a second time.
        private var isDetaching = false

        init(_ parent: InlineTextField) {
            self.parent = parent
            super.init()
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.focusRingType = .none
            field.wantsLayer = true
            field.layer?.cornerRadius = AppRadius.small
            field.layer?.borderWidth = AppBorderWidth.focused
            field.layer?.borderColor = NSColor.controlAccentColor.cgColor
            // Same font as the cell it covers, so the value doesn't shift when
            // editing starts.
            field.font = AppFont.dataCellNSFont
            // Single line: a wrapping field would outgrow its row.
            field.usesSingleLineMode = true
            field.delegate = self
        }

        func attach(to anchor: NSView) {
            anchorView = anchor
        }

        func update(text: String) {
            if field.stringValue != text {
                field.stringValue = text
            }
            place()
        }

        /// Puts the field over its cell, adding it to the clip view on the
        /// first call.
        func place() {
            guard let anchorView, anchorView.window != nil else { return }
            if field.superview == nil {
                guard let scrollView = anchorView.enclosingScrollView,
                    let tableView = scrollView.documentView as? NSTableView
                else {
                    // Not a table cell (or a table implementation we don't
                    // recognise): edit in place instead, where the row clips
                    // the focus border. Keeps the cell editable rather than
                    // blank.
                    AppLogger.warn("Inline text field found no enclosing table", category: "Keys")
                    field.frame = anchorView.bounds
                    anchorView.addSubview(field)
                    claimFocus()
                    return
                }
                let clipView = scrollView.contentView
                self.clipView = clipView
                self.tableView = tableView
                clipView.addSubview(field)
                observeGeometry(of: clipView, in: tableView)
            }
            guard let clipView, let tableView else { return }
            let row = tableView.row(for: anchorView)
            let column = tableView.column(for: anchorView)
            guard row >= 0, column >= 0 else { return }
            let cell = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
            // Native editing fills the cell; cap the field at its own height so
            // a value that wraps to two lines gets a centred field instead of a
            // tall bezel.
            let height = min(cell.height, field.intrinsicContentSize.height)
            let frame = NSRect(
                x: cell.minX,
                y: cell.midY - height / 2,
                width: cell.width,
                height: height
            )
            field.frame = clipView.convert(frame, from: tableView)
            claimFocus()
        }

        /// Claims first responder exactly once per editor lifetime. Re-claiming
        /// on every update would yank focus back after an intentional blur
        /// (click-away), making it impossible to leave the cell.
        private func claimFocus() {
            guard !didClaimFocus, let window = field.window else { return }
            window.makeFirstResponder(field)
            // Editing hands the keyboard to the window's field editor, so the
            // field itself is only the responder until the editor takes over.
            if window.firstResponder === field || window.firstResponder === field.currentEditor() {
                didClaimFocus = true
            }
        }

        /// Keeps the field on its cell across geometry changes. Scrolling needs
        /// no updates — the field shares the table's coordinate space — but
        /// column widths and the clip view's size both move the cell.
        private func observeGeometry(of clipView: NSClipView, in tableView: NSTableView) {
            clipView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(geometryDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            center.addObserver(
                self,
                selector: #selector(geometryDidChange),
                name: NSTableView.columnDidResizeNotification,
                object: tableView
            )
        }

        @objc private func geometryDidChange() {
            place()
        }

        func detach() {
            isDetaching = true
            field.removeFromSuperview()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                submit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancel()
                return true
            }
            return false
        }

        /// Submits the edited value — or just closes when it matches what the
        /// cell already shows: a no-op overwrite would still cost a write, a
        /// production confirmation, and a full key reload.
        private func submit() {
            if field.stringValue == parent.original {
                cancel()
            } else {
                parent.onSubmit()
            }
        }

        private func cancel() {
            parent.onCancel()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !isDetaching else { return }
            submit()
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }
    }
}
