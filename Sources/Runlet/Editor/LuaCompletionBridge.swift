import AppKit
import Plume

/// Bridges Runlet's Lua completions onto Plume's `SuggestController`:
/// the universe is derived live from the caret context (`redis.` members vs.
/// general globals), and the popup is Plume's word-mode session (bare word
/// at the caret → suggestion panel → replace the word).
///
/// Trigger: Plume's editor has no per-language trigger prompts beyond the
/// declared trigger characters, so the bridge relies on the `.` trigger to
/// auto-open and keeps word-mode tracking in step on every text change.
@MainActor
final class LuaCompletionBridge: EditorSuggestControlling {
    /// The `.` after `redis.` auto-opens the suggest panel (the declared
    /// trigger character); word-mode opens track typing as before.
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

// MARK: - Lua Completion Provider

/// Offers `redis.*` members after `redis.` and general globals otherwise.
///
/// The word lists are the Redis Functions Lua API surface (`redis` methods and
/// constants) plus the Lua 5.1 builtins, used purely for completion. Syntax
/// highlighting for Lua is Plume's `.lua` preset, so there is no hand-written
/// tokenizer here.
private struct LuaCompletionProvider {
    func completions(text: String, at location: Int, partial: String) -> [String] {
        if Self.isPrecededByRedisDot(text, location: location) {
            return Self.filter(Self.redisMembers, by: partial)
        }
        return Self.filter(Self.general, by: partial)
    }

    /// True when the 6 characters ending at `location` are `redis.` and they
    /// are not preceded by another word character (so `xredis.` does not match).
    static func isPrecededByRedisDot(_ text: String, location: Int) -> Bool {
        let ns = text as NSString
        guard location >= 6 else { return false }
        let before = ns.substring(with: NSRange(location: location - 6, length: 6))
        guard before == "redis." else { return false }
        if location - 7 >= 0 {
            let prev = ns.character(at: location - 7)
            if Self.isWordUnit(prev) { return false }
        }
        return true
    }

    // MARK: Completion word lists

    private static let redisMethods: Set<String> = [
        "call", "pcall", "status_reply", "error_reply", "log", "sha1hex",
        "replicate_commands", "set_repl", "breakpoint", "register_function",
        "get_repl",
    ]

    private static let redisConstants: Set<String> = [
        "LOG_DEBUG", "LOG_VERBOSE", "LOG_NOTICE", "LOG_WARNING",
        "REPL_ALL", "REPL_SLAVE", "REPL_REPLICA", "REPL_NONE", "REPL_AOF",
    ]

    private static let redisGlobals: Set<String> = ["redis", "KEYS", "ARGV"]

    private static let keywords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
        "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
        "true", "until", "while",
    ]

    private static let builtins: Set<String> = [
        // Lua 5.1 base library
        "assert", "collectgarbage", "dofile", "error", "getfenv", "getmetatable",
        "ipairs", "load", "loadfile", "loadstring", "module", "next", "pairs",
        "pcall", "print", "rawequal", "rawget", "rawset", "select", "setfenv",
        "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall",
        "require",
        // standard libraries
        "coroutine", "math", "io", "os", "string", "table", "package",
        // Redis-provided
        "cjson", "cmsgpack", "bit",
    ]

    private static let redisMembers: [String] =
        (redisMethods.union(redisConstants)).sorted()

    private static let general: [String] =
        (redisGlobals.union(builtins).union(keywords)).sorted()

    private static func filter(_ list: [String], by partial: String) -> [String] {
        guard !partial.isEmpty else { return list }
        let prefix = partial.lowercased()
        return list.filter { $0.lowercased().hasPrefix(prefix) }
    }

    private static func isWordUnit(_ unit: unichar) -> Bool {
        (unit >= 48 && unit <= 57)  // 0-9
            || (unit >= 65 && unit <= 90)  // A-Z
            || (unit >= 97 && unit <= 122)  // a-z
            || unit == 95  // _
    }
}
