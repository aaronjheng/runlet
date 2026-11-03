import AppKit
import Plume
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterLua

/// Runlet's `SyntaxProfile` library: the languages Runlet's editors speak.
/// Plume ships no grammars by design - every syntax is a host-side profile.
/// These wrap the same tree-sitter grammars the app's legacy highlighters
/// use (`TreeSitterBash` / `TreeSitterLua`), with paint walks structured
/// after the package's own (JSON/XML/JS): depth-first recursion, node types
/// in, role colors out, unknown nodes fall through to their children so
/// grammar drift costs a color, never a crash.
/// The role palette for one paint: resolved from `EditorTheme` on the main
/// actor before the walk starts, so the nonisolated walk never touches
/// main-actor chrome mid-recursion.
struct RoleColors: Sendable {
    let plain: NSColor
    let string: NSColor
    let number: NSColor
    let key: NSColor
    let keyword: NSColor

    /// Nonisolated by design: `EditorTheme`'s tokens are
    /// `nonisolated(unsafe)` statics (set-once at launch), and `NSColor`
    /// wrapping is thread-safe. Paints always run on the main thread anyway.
    nonisolated static func current() -> RoleColors {
        RoleColors(
            plain: NSColor(EditorTheme.syntaxPlain),
            string: NSColor(EditorTheme.syntaxString),
            number: NSColor(EditorTheme.syntaxNumber),
            key: NSColor(EditorTheme.syntaxKey),
            keyword: NSColor(EditorTheme.syntaxKeyword))
    }
}

extension SyntaxProfile {
    /// Shell commands (the shell tab's input history, curl previews): pipes
    /// and redirects stay plain, flags/keywords take the keyword color,
    /// strings and numbers the shared token colors. `#` line comments.
    public static let bash = SyntaxProfile(
        id: "bash",
        language: { tree_sitter_bash().map { Language($0) } },
        paint: { root, length, cursor, runs in
            let colors = RoleColors.current()
            ProfilePaint.bash(node: root, length: length, colors: colors, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "# "))

    /// Lua scripts (the Functions editor): API member chains (`redis.call`)
    /// read as one key-colored surface, keywords the keyword color,
    /// strings/numbers the shared token colors. `--` line comments.
    public static let lua = SyntaxProfile(
        id: "lua",
        language: { tree_sitter_lua().map { Language($0) } },
        paint: { root, length, cursor, runs in
            let colors = RoleColors.current()
            ProfilePaint.lua(node: root, length: length, colors: colors, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "-- "))
}

/// The painters. Nonisolated: Plume's paint closure runs inside
/// text-storage processing on the main thread, but the closure type is
/// nonisolated, so the walks resolve theme colors up front (in the
/// profile, on the main actor) and take them as parameters.
private enum ProfilePaint {
    // MARK: Bash

    private static let bashKeywordTokens: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done",
        "while", "until", "case", "esac", "function", "select", "coproc",
        "return", "local", "export", "readonly", "declare", "unset",
        "source", "exit", "time",
    ]

    static func bash(
        node: Node, length: Int, colors: RoleColors, cursor: inout Int, runs: inout [(NSRange, NSColor)]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "comment":
            leaf(node, colors.plain, length, &cursor, &runs)
        case "string", "raw_string", "heredoc_body", "ansic_string":
            leaf(node, colors.string, length, &cursor, &runs)
        case "number":
            leaf(node, colors.number, length, &cursor, &runs)
        case "variable_name", "test_operator":
            leaf(node, colors.key, length, &cursor, &runs)
        default:
            if node.childCount == 0, bashKeywordTokens.contains(type) {
                leaf(node, colors.keyword, length, &cursor, &runs)
            } else {
                forEachChild(node) { bash(node: $0, length: length, colors: colors, cursor: &cursor, runs: &runs) }
            }
        }
    }

    // MARK: Lua

    private static let luaKeywordTokens: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or",
        "repeat", "return", "then", "true", "until", "while",
    ]

    static func lua(
        node: Node, length: Int, colors: RoleColors, cursor: inout Int, runs: inout [(NSRange, NSColor)]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "comment":
            leaf(node, colors.plain, length, &cursor, &runs)
        case "string", "string_content":
            leaf(node, colors.string, length, &cursor, &runs)
        case "number":
            leaf(node, colors.number, length, &cursor, &runs)
        case "identifier", "function_name", "method":
            // API member chains (`redis.call`) read as one key-colored
            // surface, matching Plume's JS callee treatment.
            leaf(node, colors.key, length, &cursor, &runs)
        default:
            if node.childCount == 0, luaKeywordTokens.contains(type) {
                leaf(node, colors.keyword, length, &cursor, &runs)
            } else {
                forEachChild(node) { lua(node: $0, length: length, colors: colors, cursor: &cursor, runs: &runs) }
            }
        }
    }

    // MARK: Shared leaves

    /// Emits one colored run for the node's UTF-16 range (`Node.range` is
    /// already in UTF-16 units on SwiftTreeSitter), clamped against the
    /// document length.
    private static func leaf(
        _ node: Node, _ color: NSColor, _ length: Int,
        _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]
    ) {
        let range = node.range
        var location = min(max(range.location, 0), length)
        var end = min(max(NSMaxRange(range), location), length)
        if end < location { end = location }
        location = min(location, end)
        guard end - location > 0 else { return }
        if location > cursor { cursor = location }
        runs.append((NSRange(location: location, length: end - location), color))
        cursor = end
    }

    private static func forEachChild(_ node: Node, _ paint: (Node) -> Void) {
        for index in 0..<node.childCount {
            if let child = node.child(at: index) { paint(child) }
        }
    }
}
