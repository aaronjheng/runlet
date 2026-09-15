import Foundation
import SwiftTreeSitter
import TreeSitterJSON

// MARK: - Tree-sitter JSON Highlighter

/// Syntax highlighting backed by the tree-sitter JSON grammar.
///
/// Uses the upstream `highlights.scm` query (vendored in
/// `Vendor/tree-sitter-json/queries`) to color JSON shown in the string key
/// detail view. Capture names (`string`, `number`, `constant.builtin`,
/// `string.special.key`, ...) are mapped onto the app's shared
/// `SyntaxTokenType` color palette.
///
/// `Parser` and `Query` are not `Sendable`; the class is marked
/// `@unchecked Sendable` to satisfy the `SyntaxTokenizer` protocol. Instances
/// are only used from the main actor, so this is safe.
final class TreeSitterJsonHighlighter: @unchecked Sendable, SyntaxTokenizer {
    /// Shared instance used by the key-value detail view. Query compilation is
    /// expensive; sharing avoids recompiling it on every body evaluation.
    /// Parses are always fresh (read-only display), so sharing the parser
    /// across documents is safe.
    static let shared = TreeSitterJsonHighlighter()

    private let parser = Parser()
    private let query: Query
    private let language = Language(language: tree_sitter_json())

    init() {
        self.query = Self.makeQuery(language: language)
        try? parser.setLanguage(language)
    }

    func tokens(in text: String) -> [SyntaxToken] {
        guard let tree = parser.parse(text) else { return [] }
        let cursor = query.execute(in: tree)
        let namedRanges = cursor.highlights()

        return namedRanges.compactMap { namedRange -> SyntaxToken? in
            let nsRange = namedRange.range
            guard nsRange.length > 0 else { return nil }
            guard let type = TreeSitterJsonHighlighter.mapCapture(namedRange.name) else { return nil }
            return SyntaxToken(range: nsRange, type: type)
        }
    }

    private static func makeQuery(language: Language) -> Query {
        let config = try? LanguageConfiguration(language, name: "JSON", bundleName: "TreeSitterJSON_TreeSitterJSON")
        if let query = config?.queries[.highlights] {
            return query
        }
        if let url = highlightsURL, let query = try? Query(language: language, url: url) {
            return query
        }
        // swiftlint:disable:next force_try
        return try! Query(language: language, data: Data())
    }

    /// Maps a tree-sitter JSON highlight capture name to the shared
    /// `SyntaxTokenType`. The leading dot-component drives color selection.
    private static func mapCapture(_ name: String) -> SyntaxTokenType? {
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "string":
            // `string.special.key` (object keys) vs plain `string` both map to
            // the string family; keys reuse `.type` (teal) to echo the old
            // hand-written highlighter's key/string distinction.
            return name == "string.special.key" ? .type : .string
        case "number":
            return .number
        case "constant", "constant.builtin":
            return .constant
        case "escape":
            return .constant
        case "comment":
            return .comment
        default:
            return nil
        }
    }

    private static let highlightsURL: URL? = {
        Bundle.main.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries")
            ?? Bundle.main.url(forResource: "highlights", withExtension: "scm")
    }()
}
