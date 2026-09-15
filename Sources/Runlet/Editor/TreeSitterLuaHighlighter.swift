import Foundation
import SwiftTreeSitter
import TreeSitterLua

// MARK: - Tree-sitter Lua Highlighter

/// Syntax highlighting backed by the tree-sitter Lua grammar.
///
/// This replaces the hand-written `LuaTokenizer` with tree-sitter's incremental
/// parser and the upstream `highlights.scm` query (vendored in
/// `Vendor/tree-sitter-lua/queries`). Tree-sitter produces a real syntax tree,
/// so highlighting is more accurate than a pure lexer (e.g. it distinguishes
/// function-call arguments from declarations, understands block structure).
///
/// Token capture names from `highlights.scm` (e.g. `keyword`, `string`,
/// `function`, `constant.builtin`) are mapped onto the app's shared
/// `SyntaxTokenType` color palette.
///
/// `Parser` and `Query` are not `Sendable`, so this class is marked
/// `@unchecked Sendable` to satisfy the `SyntaxTokenizer` protocol. Instances
/// are only ever used from the main actor (text view edits), so this is safe.
///
/// A single shared instance serves the Lua editor and the read-only library
/// detail view: the highlights query is compiled once per process, and the
/// previous parse tree is kept so consecutive parses are incremental (see
/// `parse(_:)`) instead of full re-parses on every keystroke.
final class TreeSitterLuaHighlighter: @unchecked Sendable, SyntaxTokenizer {
    /// Shared instance used by the Lua editor and the library detail view.
    static let shared = TreeSitterLuaHighlighter()

    private let parser = Parser()
    private static let language = Language(language: tree_sitter_lua())

    /// Compiled once per process. `LanguageConfiguration` bundle lookup and
    /// query compilation used to run on every `init()` — i.e. on every
    /// SwiftUI body evaluation that constructed a fresh highlighter.
    private static let query: Query = {
        // Load the highlights.scm query that ships with the vendored
        // TreeSitterLua package (bundled as a resource). The bundle follows
        // SPM's `TreeSitterLua_TreeSitterLua` naming convention. Fall back to
        // a raw file lookup, then to an empty query (no highlighting) so the
        // view never crashes on init.
        let config = try? LanguageConfiguration(language, name: "Lua", bundleName: "TreeSitterLua_TreeSitterLua")
        if let query = config?.queries[.highlights] {
            return query
        }
        if let url = highlightsURL, let query = try? Query(language: language, url: url) {
            return query
        }
        // swiftlint:disable:next force_try
        return try! Query(language: language, data: Data())
    }()

    /// The tree and text of the previous parse, used for incremental
    /// re-parsing. Main-actor access only.
    private var previousTree: MutableTree?
    private var previousText = ""

    init() {
        try? parser.setLanguage(Self.language)
    }

    func tokens(in text: String) -> [SyntaxToken] {
        guard let tree = parse(text) else { return [] }

        // `Query.execute(in:)` returns a `QueryCursor` that is itself a
        // `Sequence` of `QueryMatch`. The Lua highlight query does not rely on
        // #eq?/#match? predicates, so we can consume it directly.
        let cursor = Self.query.execute(in: tree)
        let namedRanges = cursor.highlights()

        return namedRanges.compactMap { namedRange -> SyntaxToken? in
            let nsRange = namedRange.range
            guard nsRange.length > 0 else { return nil }
            guard let type = TreeSitterLuaHighlighter.mapCapture(namedRange.name) else { return nil }
            return SyntaxToken(range: nsRange, type: type)
        }
    }

    // MARK: Incremental parsing

    /// Parses `text`, reusing the previous tree where possible.
    ///
    /// Tree-sitter only reuses subtrees it knows are unchanged, so the
    /// minimal contiguous edit between the previous and current text is
    /// applied to the old tree first (`ts_tree_edit`); reuse is then limited
    /// to regions outside that edit. When the document changes entirely (the
    /// shared instance serves both the editor and the read-only detail view),
    /// the computed edit spans the whole text and the parse degrades to a
    /// fresh one — always correct, just without reuse.
    private func parse(_ text: String) -> MutableTree? {
        let tree: MutableTree?
        if let oldTree = previousTree {
            oldTree.edit(Self.diffEdit(from: previousText, to: text))
            tree = parser.parse(tree: oldTree, string: text)
        } else {
            tree = parser.parse(text)
        }
        previousTree = tree
        previousText = text
        return tree
    }

    /// The single contiguous edit covering every difference between the two
    /// texts. Offsets are UTF-16 code units doubled into tree-sitter bytes
    /// (the parser input is UTF-16); points are unused for byte ranges.
    private static func diffEdit(from oldText: String, to newText: String) -> InputEdit {
        let old = Array(oldText.utf16)
        let new = Array(newText.utf16)

        var start = 0
        let maxStart = min(old.count, new.count)
        while start < maxStart, old[start] == new[start] {
            start += 1
        }

        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }

        let zero = Point(row: 0, column: 0)
        return InputEdit(
            startByte: start * 2,
            oldEndByte: oldEnd * 2,
            newEndByte: newEnd * 2,
            startPoint: zero,
            oldEndPoint: zero,
            newEndPoint: zero
        )
    }

    // MARK: Capture -> color mapping

    /// Maps a tree-sitter highlight capture name (possibly dot-separated, e.g.
    /// `keyword.return`, `function.builtin`, `string.special`) to the app's
    /// shared `SyntaxTokenType`. The leading component is what matters for
    /// color selection; unknown captures are dropped (rendered as default).
    private static func mapCapture(_ name: String) -> SyntaxTokenType? {
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "keyword", "conditional", "repeat", "keyword.function", "keyword.return":
            return .keyword
        case "string", "string.special":
            return .string
        case "number", "float":
            return .number
        case "comment":
            return .comment
        case "function", "function.call", "function.builtin", "method", "method.call":
            return .builtin
        case "constant", "constant.builtin":
            return .constant
        case "type", "type.builtin":
            return .type
        case "variable", "variable.builtin":
            return .member
        default:
            return nil
        }
    }

    // MARK: Query loading fallback

    /// Locates `highlights.scm` in the main bundle's `TreeSitterLua` resource
    /// bundle, used when `LanguageConfiguration`'s bundle lookup fails.
    private static let highlightsURL: URL? = {
        Bundle.main.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries")
            ?? Bundle.main.url(forResource: "highlights", withExtension: "scm")
    }()
}
