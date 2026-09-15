import AppKit
import SwiftUI

/// Standard font tokens used across the app.
///
/// Using a single source of truth for monospaced fonts keeps data-heavy views
/// consistent and makes future size adjustments easy.
enum AppFont {
    static let monoBody = Font.system(.body, design: .monospaced)
    static let monoSubheadline = Font.system(.subheadline, design: .monospaced)
    static let monoCaption = Font.system(.caption, design: .monospaced)
    static let monoCaption2 = Font.system(.caption2, design: .monospaced)
    static let dataCell = Font.system(.body, design: .monospaced)

    /// AppKit counterpart of `dataCell` for `NSViewRepresentable` text views
    /// (`SelectableText`, editors) that take `NSFont`. Computed so no shared
    /// mutable `NSFont` state crosses concurrency domains (`NSFont` caches
    /// system fonts internally, so this stays cheap).
    static var dataCellNSFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }
}
