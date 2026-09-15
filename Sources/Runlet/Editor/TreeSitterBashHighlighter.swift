import Foundation
import SwiftTreeSitter
import SwiftUI
import TreeSitterBash

// MARK: - Tree-sitter Bash Highlighter

/// Syntax highlighting backed by the tree-sitter Bash grammar.
///
/// This replaces the hand-written `ShellSyntaxHighlighter` (regex tokenizer +
/// hardcoded Redis command list) with tree-sitter's parser and the upstream
/// `highlights.scm` query (bundled as a resource by the `TreeSitterBash` SPM
/// package). Tree-sitter produces a real syntax tree, so highlighting is more
/// accurate: command names, quoted strings, comments, variables, option flags,
/// and operators are all recognized by the grammar.
///
/// The stock query contains a `#match?` predicate (option flags such as `-a`).
/// The plain `QueryCursor` sequence does not evaluate predicates, so matches
/// are validated against `Predicate.Context` before rendering.
///
/// `Parser` and `Query` are not `Sendable`, so this class is marked
/// `@unchecked Sendable` to satisfy the `SyntaxTokenizer` protocol. Instances
/// are only ever used from the main actor, so this is safe.
final class TreeSitterBashHighlighter: @unchecked Sendable, SyntaxTokenizer {
    /// Shared instance used by shell history rows. The parser and query are
    /// reused across every row; only the parse itself is per-command.
    static let shared = TreeSitterBashHighlighter()

    private let parser = Parser()
    private let query: Query
    private let language = Language(language: tree_sitter_bash())

    init() {
        self.query = Self.makeQuery(language: language)
        try? parser.setLanguage(language)
    }

    func tokens(in text: String) -> [SyntaxToken] {
        guard let tree = parser.parse(text) else { return [] }

        // Evaluate `#match?`/`#eq?` predicates (e.g. `(command (_) @constant
        // (#match? @constant "^-"))`) before consuming the matches.
        let context = Predicate.Context(string: text)
        let cursor = query.execute(in: tree)
        let namedRanges =
            cursor
            .filter { $0.allowed(in: context) }
            .highlights()

        return namedRanges.compactMap { namedRange -> SyntaxToken? in
            let nsRange = namedRange.range
            guard nsRange.length > 0 else { return nil }
            guard let type = Self.mapCapture(namedRange.name) else { return nil }
            return SyntaxToken(range: nsRange, type: type)
        }
    }

    /// Renders a command line as an attributed string for shell history rows.
    /// Command names are bolded, echoing the previous highlighter's emphasis.
    ///
    /// Results are cached per command text. History rows are re-created on
    /// every keystroke in the input field (before the `Equatable` check) and
    /// whenever a `LazyVStack` row scrolls back into view, so re-parsing the
    /// same commands each time would dominate rendering cost. Keying the cache
    /// by command text (rather than entry) lets repeated commands share one
    /// parse. Access is main-actor only, matching the rest of this type.
    func highlight(_ text: String) -> AttributedString {
        if let cached = highlightCache[text] {
            return cached
        }
        let rendered = renderHighlighted(text)
        highlightCache[text] = rendered
        if highlightCache.count > Self.highlightCacheLimit {
            highlightCache.removeAll(keepingCapacity: true)
        }
        return rendered
    }

    private func renderHighlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for token in tokens(in: text) {
            guard token.range.length > 0,
                let attrRange = Range(token.range, in: attributed)
            else { continue }
            attributed[attrRange].foregroundColor = Color(nsColor: token.type.color)
            if token.type == .builtin {
                attributed[attrRange].font = AppFont.dataCell.bold()
            }
        }
        return attributed
    }

    /// Rendered command lines, keyed by command text. Shell history is capped
    /// at 200 entries and commands are short, so memory use is negligible; the
    /// limit is a safety net against unbounded growth.
    private var highlightCache: [String: AttributedString] = [:]
    private static let highlightCacheLimit = 512

    // MARK: Capture -> color mapping

    /// Maps a tree-sitter highlight capture name to the app's shared
    /// `SyntaxTokenType`. The leading component is what matters for color
    /// selection; unknown captures (e.g. `embedded`) are dropped so those
    /// ranges render as default text.
    private static func mapCapture(_ name: String) -> SyntaxTokenType? {
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "keyword", "operator":
            return .keyword
        case "string":
            return .string
        case "comment":
            return .comment
        case "function":
            return .builtin
        case "constant":
            return .constant
        case "property":
            return .member
        case "number":
            return .number
        default:
            return nil
        }
    }

    // MARK: Query loading fallback

    /// Locates `highlights.scm` in the main bundle's `TreeSitterBash` resource
    /// bundle, used when `LanguageConfiguration`'s bundle lookup fails.
    private static let highlightsURL: URL? = {
        Bundle.main.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries")
            ?? Bundle.main.url(forResource: "highlights", withExtension: "scm")
    }()

    private static func makeQuery(language: Language) -> Query {
        let config = try? LanguageConfiguration(language, name: "Bash", bundleName: "TreeSitterBash_TreeSitterBash")
        if let query = config?.queries[.highlights] {
            return query
        }
        if let url = highlightsURL, let query = try? Query(language: language, url: url) {
            return query
        }
        // swiftlint:disable:next force_try
        return try! Query(language: language, data: Data())
    }
}
