import AppKit
import Plume

/// Bridges Runlet's Lua completions onto Plume's `SuggestController`:
/// the universe is derived live from the caret context (`redis.` members vs.
/// general globals), and the popup is Plume's word-mode session (bare word
/// at the caret → suggestion panel → replace the word).
///
/// Trigger: the legacy `SyntaxTextEditor` prompted via `textView.complete`
/// after `redis.`. Plume's editor has no per-language triggers, so the
/// bridge opens the session itself when the caret lands just past `redis.`
/// and the word is empty (word-mode needs a fragment to open on).
@MainActor
final class LuaCompletionBridge: EditorSuggestControlling {
    /// The `.` after `redis.` auto-opens the suggest panel (Monaco's
    /// triggerCharacters); word-mode opens track typing as before.
    private let engine = SuggestController(triggerCharacters: ["."])
    private let provider = LuaCompletionProvider()

    func candidatesChanged(_ candidates: [Any]) {
        // The Lua universe is derived, not passed: nothing to adopt.
    }

    func textChanged(_ textView: NSTextView) {
        syncUniverse(textView: textView)
        // The engine auto-opens on the `.` trigger; a plain textChanged
        // keeps word-mode tracking in step.
        engine.textChanged(textView)
    }

    func selectionChanged(_ textView: NSTextView) {
        engine.selectionChanged(textView)
    }

    func handleCommand(_ selector: Selector) -> Bool {
        engine.handleCommand(selector)
    }

    var isVisible: Bool { engine.isVisible }

    func hide() {
        engine.hide()
    }

    /// Recomputes the word-mode universe from the current text + caret.
    private func syncUniverse(textView: NSTextView) {
        let text = textView.string
        let caret = textView.selectedRange.location
        let ns = text as NSString
        let wordRange = ns.range(
            of: "\\w+$",
            options: [.regularExpression, .backwards],
            range: NSRange(location: 0, length: min(caret, ns.length)))
        let partial = wordRange.location == NSNotFound ? "" : ns.substring(with: wordRange)
        engine.setWordCandidates(
            provider.completions(text: text, at: caret, partial: partial)
                .map { SuggestItem(name: $0) })
    }
}
