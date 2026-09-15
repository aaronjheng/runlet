import AppKit
import SwiftUI

/// A read-only, selectable text view backed by `NSTextView`.
///
/// SwiftUI's `Text` with `.textSelection(.enabled)` lazily swaps in an
/// `NSTextView` on first click, which causes a visible relayout (especially
/// around blank lines) -- a "jitter". This wrapper uses a bare `NSTextView`
/// (no enclosing scroll view) from the start, so there is no swap. To make a
/// bare `NSTextView` size correctly inside SwiftUI's layout system, it reports
/// an `intrinsicContentSize` computed from its layout manager.
struct SelectableText: NSViewRepresentable {
    let text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Optional syntax tokenizer. When provided, the text is colored according
    /// to the tokenizer's token types; otherwise it renders as plain text.
    var tokenizer: (any SyntaxTokenizer)?

    init(
        text: String,
        font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        tokenizer: (any SyntaxTokenizer)? = nil
    ) {
        self.text = text
        self.font = font
        self.tokenizer = tokenizer
    }

    func makeNSView(context: Context) -> AutoSizingTextView {
        let textView = AutoSizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        // Rich text is required to carry per-range foreground colors; turning
        // it on does not affect selectability or copy behavior.
        textView.isRichText = tokenizer != nil
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = font
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        if let tokenizer {
            applyHighlighting(to: textView, tokenizer: tokenizer)
        }
        return textView
    }

    func updateNSView(_ nsView: AutoSizingTextView, context: Context) {
        var didMutate = false
        if nsView.string != text {
            nsView.string = text
            didMutate = true
        }
        if nsView.font != font {
            nsView.font = font
            didMutate = true
        }
        // Re-apply highlighting whenever the text or font changed.
        if didMutate, let tokenizer {
            applyHighlighting(to: nsView, tokenizer: tokenizer)
        }
    }

    private func applyHighlighting(to textView: NSTextView, tokenizer: any SyntaxTokenizer) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: whole)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        for token in tokenizer.tokens(in: source) where token.range.length > 0 {
            guard token.range.location + token.range.length <= whole.length else { continue }
            storage.addAttribute(.foregroundColor, value: token.type.color, range: token.range)
        }
        storage.endEditing()
    }
}

/// An `NSTextView` that keeps its `intrinsicContentSize` in sync with its laid
/// out text height, so SwiftUI can measure it without a wrapping scroll view.
final class AutoSizingTextView: NSTextView {
    override var string: String {
        didSet {
            invalidateIntrinsicContentSize()
        }
    }

    override var font: NSFont? {
        didSet {
            invalidateIntrinsicContentSize()
        }
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: usedRect.height)
    }
}
