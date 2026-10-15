import SwiftUI
import UniformTypeIdentifiers

// MARK: - Text Export Document

/// Plain-text wrapper for `fileExporter`, carrying a suggested filename in
/// the save dialog. Shared by views that export textual artifacts (key
/// values, profiler captures, analysis reports).
struct TextExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    static let writableContentTypes: [UTType] = [.plainText]

    let text: String
    var defaultFilename: String

    init(text: String, defaultFilename: String? = nil) {
        self.text = text
        self.defaultFilename = defaultFilename ?? "export.txt"
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(data: data, encoding: .utf8) ?? ""
        defaultFilename = "export.txt"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
