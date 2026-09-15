import AppKit
import SwiftUI

// MARK: - Syntax Text View

/// An editable, syntax-highlighted text view backed by `NSTextView`.
///
/// SwiftUI's `TextEditor` cannot render attributed (colored) text, so this wraps
/// an `NSTextView` whose text storage is recolored after every edit by a
/// pluggable `SyntaxTokenizer`. It also adds auto-indentation, bracket/quote
/// pairing, and context-aware completion via a `SyntaxCompletionProvider`.
///
/// The shell is language-agnostic: Lua and (future) JavaScript each supply
/// their own tokenizer + completion provider without touching this view.
struct SyntaxTextEditor: NSViewRepresentable {
    @Binding var text: String
    let tokenizer: any SyntaxTokenizer
    let completionProvider: (any SyntaxCompletionProvider)?
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var backgroundColor: Color = AppColor.codeBackground

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SyntaxTextView()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.usesRuler = false
        textView.focusRingType = .default
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = NSColor(backgroundColor)
        textView.insertionPointColor = .labelColor
        textView.typingAttributes = [
            .foregroundColor: NSColor.labelColor,
            .font: font,
        ]
        textView.delegate = context.coordinator
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.size = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainerInset = NSSize(width: 0, height: 4)

        textView.coordinator = context.coordinator
        textView.string = text
        context.coordinator.applyHighlightingIfNeeded(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SyntaxTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
        // `textDidChange` has already highlighted the current text (the
        // binding write above synchronously re-runs `updateNSView`); skip the
        // second full parse when nothing changed.
        context.coordinator.applyHighlightingIfNeeded(to: textView)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxTextEditor
        /// Suppresses highlighting when we programmatically reset `string`.
        private var isSettingText = false
        /// The text that was last highlighted. `textDidChange` highlights
        /// immediately after every edit; the `updateNSView` pass that follows
        /// (triggered by the binding write) then skips the redundant second
        /// highlight.
        private var lastHighlightedText: String?

        init(_ parent: SyntaxTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            applyHighlighting(to: textView)
        }

        // MARK: Highlighting

        /// Re-applies highlighting only if the current text has not been
        /// highlighted yet. `updateNSView` runs right after `textDidChange`
        /// handled the edit, so this avoids a second full parse per keystroke
        /// and per body re-evaluation.
        func applyHighlightingIfNeeded(to textView: NSTextView) {
            if textView.string != lastHighlightedText {
                applyHighlighting(to: textView)
            }
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: whole)
            if !text.isEmpty {
                storage.addAttribute(
                    .foregroundColor, value: NSColor.labelColor, range: whole
                )
                for token in parent.tokenizer.tokens(in: text)
                where token.range.length > 0 {
                    guard token.range.location + token.range.length <= whole.length
                    else { continue }
                    storage.addAttribute(
                        .foregroundColor, value: token.type.color, range: token.range
                    )
                }
            }
            storage.endEditing()
            lastHighlightedText = text
        }

        // MARK: Completion

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int?>?
        ) -> [String] {
            index?.pointee = 0
            guard let provider = parent.completionProvider else { return [] }
            let ns = textView.string as NSString
            let partial = ns.substring(with: charRange)
            return provider.completions(
                text: textView.string, at: charRange.location, partial: partial
            )
        }
    }
}

// MARK: - SyntaxTextView (NSTextView subclass)

/// The `NSTextView` subclass owning editor behaviors: auto-indent, bracket
/// pairing, and the `redis.`-triggered completion prompt.
final class SyntaxTextView: NSTextView {
    fileprivate weak var coordinator: SyntaxTextEditor.Coordinator?

    private let pairs: [Character: Character] = [
        "(": ")",
        "[": "]",
        "{": "}",
        "\"": "\"",
        "'": "'",
    ]

    private let closingChars: Set<Character> = [")", "]", "}"]

    override func paste(_ sender: Any?) {
        // Always paste as plain text so external formatting never overrides the
        // syntax-highlighted storage.
        pasteAsPlainText(nil)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let typed = string as? String, !typed.isEmpty else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Auto-indent on newline: inherit the previous line's leading
        // whitespace, and add one indent level if that line opens a block.
        if typed == "\n" {
            if let indent = autoIndent(forNewlineAt: replacementRange.location) {
                super.insertText("\n" + indent, replacementRange: replacementRange)
                return
            }
        }

        // Bracket / quote pairing: typing an opener inserts the closer and
        // places the caret between them. Typing a closer when the next char is
        // the same closer just moves past it instead of duplicating.
        if typed.count == 1, let ch = typed.first {
            if let closer = pairs[ch], !isInsideStringOrComment(at: selectedRange.location) {
                super.insertText(String(ch) + String(closer), replacementRange: replacementRange)
                selectedRange = NSRange(
                    location: replacementRange.location + 1, length: 0
                )
                return
            }
            if closingChars.contains(ch) {
                if let next = character(at: selectedRange.location), next == ch {
                    selectedRange = NSRange(
                        location: selectedRange.location + 1, length: 0
                    )
                    return
                }
            }
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        // Auto-prompt completions right after typing `redis.`.
        coordinator?.maybePromptCompletion(in: self)
    }

    // MARK: Indentation

    private let indentUnit = "    "  // 4 spaces, matching the Lua template

    private func autoIndent(forNewlineAt location: Int) -> String? {
        let ns = string as NSString
        guard location > 0, location <= ns.length else { return nil }

        // Find the start of the line being left.
        var lineStart = location - 1
        while lineStart > 0, ns.character(at: lineStart - 1) != 0x0A {  // newline
            lineStart -= 1
        }
        let line = ns.substring(
            with: NSRange(location: lineStart, length: location - lineStart)
        )

        // Capture leading whitespace of the current line.
        var leading = ""
        for char in line {
            if char == " " || char == "\t" {
                leading.append(char)
            } else {
                break
            }
        }

        // Add an indent level if the line opens a block (ends with a keyword
        // such as `then`, `do`, `function`, etc., ignoring trailing whitespace).
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let blockOpeners: Set<String> = [
            "then", "do", "function", "else", "repeat", "while", "for", "if",
        ]
        let opener =
            trimmed
            .components(separatedBy: .whitespaces)
            .last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        if let opener, blockOpeners.contains(opener) {
            leading += indentUnit
        }

        return leading.isEmpty ? "" : leading
    }

    // MARK: Helpers

    private func character(at location: Int) -> Character? {
        let ns = string as NSString
        guard location >= 0, location < ns.length else { return nil }
        guard let scalar = UnicodeScalar(ns.character(at: location)) else { return nil }
        return Character(scalar)
    }

    /// A cheap heuristic: returns true if the caret sits inside a string or
    /// comment, so we don't auto-pair quotes inside string literals.
    private func isInsideStringOrComment(at location: Int) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let check = min(location, storage.length - 1)
        let attr = storage.attributes(
            at: check, longestEffectiveRange: nil, in: NSRange(location: 0, length: storage.length)
        )
        if let color = attr[.foregroundColor] as? NSColor {
            // Comment / string colors are the only secondary-ish hues applied.
            return color == NSColor(AppColor.syntaxString)
                || color == .secondaryLabelColor
        }
        return false
    }
}

extension SyntaxTextEditor.Coordinator {
    /// Triggers the completion popup when the caret is just past `redis.`.
    fileprivate func maybePromptCompletion(in textView: NSTextView) {
        guard parent.completionProvider is LuaCompletionProvider else { return }
        let text = textView.string as NSString
        let cursor = textView.selectedRange.location
        guard LuaCompletionProvider.isPrecededByRedisDot(text as String, location: cursor) else { return }
        textView.complete(nil)
    }
}
