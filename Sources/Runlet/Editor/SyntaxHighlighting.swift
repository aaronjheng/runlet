import AppKit
import SwiftUI

// MARK: - Syntax Tokenization Protocol

/// A range of source text classified into a syntax category for highlighting.
struct SyntaxToken {
    let range: NSRange
    let type: SyntaxTokenType
}

/// Syntax categories with a stable color mapping. New languages reuse these so
/// the editor's color palette stays consistent across Lua, JavaScript, etc.
enum SyntaxTokenType {
    case keyword
    case string
    case number
    case comment
    case builtin
    case type  // language-specific "special" globals (e.g. redis, KEYS)
    case member  // API member (e.g. redis.call)
    case constant  // named constants (e.g. redis.LOG_DEBUG)

    var color: NSColor {
        switch self {
        case .keyword: NSColor(AppColor.syntaxKey)
        case .string: NSColor(AppColor.syntaxString)
        case .number: NSColor(AppColor.syntaxNumber)
        case .comment: .secondaryLabelColor
        case .builtin: NSColor(AppColor.syntaxBuiltin)
        case .type: NSColor(AppColor.syntaxType)
        case .member: NSColor(AppColor.syntaxBuiltin)
        case .constant: NSColor(AppColor.syntaxConstant)
        }
    }
}

/// Tokenizes source text into highlightable ranges. The editor calls this
/// after every edit.
///
/// Implementations may keep parse state for incremental re-parsing
/// (`TreeSitterLuaHighlighter` reuses its previous tree); in practice they are
/// confined to the main actor.
///
/// Highlighting itself is provided by tree-sitter grammars
/// (`TreeSitterLuaHighlighter`, `TreeSitterJsonHighlighter`); this protocol is
/// the language-agnostic surface the editor shell consumes.
protocol SyntaxTokenizer: Sendable {
    func tokens(in text: String) -> [SyntaxToken]
}

/// Provides context-aware completions at a source location.
protocol SyntaxCompletionProvider: Sendable {
    /// `partial` is the word being typed (may be empty). `location` is the
    /// caret's absolute index into `text`.
    func completions(text: String, at location: Int, partial: String) -> [String]
}

// MARK: - Lua Completion Provider

/// Offers `redis.*` members after `redis.` and general globals otherwise.
///
/// The word lists are the Redis Functions Lua API surface (`redis` methods and
/// constants) plus the Lua 5.1 builtins, used purely for completion. Syntax
/// highlighting for Lua is handled by `TreeSitterLuaHighlighter`, so there is
/// no hand-written tokenizer here.
struct LuaCompletionProvider: SyntaxCompletionProvider {
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
