import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - String Detail View

struct StringDetailView: View {
    let key: String
    let value: String
    @Binding var format: StringValueFormat
    let onSave: (String) -> Void

    @State private var isEditing = false
    @State private var editValue = ""
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: TextExportDocument?
    @State private var importError: String?

    /// Import guard: values beyond what the viewer can display are refused,
    /// so the editor stays consistent with the viewer's in-memory limits.
    private static let importSizeLimit = 10_000_000

    var body: some View {
        // Parse/transform once per body: the JSON branch needs the pretty
        // string, every other branch needs exactly one decode pass.
        let jsonPretty = format == .json ? StringValueFormatter.prettyPrintedJSON(value) : nil
        VStack(spacing: 0) {
            if isEditing {
                VStack(spacing: AppSpacing.small) {
                    PlainTextEditor(text: $editValue)
                        .font(AppFont.monoBody)
                        .padding(AppSpacing.small)
                        .background(AppColor.codeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.medium)
                                .stroke(Color.accentColor, lineWidth: AppBorderWidth.focused)
                        )

                    HStack(spacing: AppSpacing.small) {
                        Spacer()
                        Button("Cancel") {
                            isEditing = false
                        }
                        .buttonStyle(.borderless)
                        .hoverBackground()
                        .keyboardShortcut(.cancelAction)
                        Button("Save") {
                            onSave(editValue)
                            isEditing = false
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(AppSpacing.large)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        if let jsonPretty {
                            SelectableText(
                                text: jsonPretty,
                                font: AppFont.dataCellNSFont,
                                tokenizer: TreeSitterJsonHighlighter.shared
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppSpacing.large)
                        } else {
                            let decoded = StringValueFormatter.decoded(value, format: format)
                            if let error = decoded.error {
                                ErrorBanner(message: error)
                            }
                            Text(decoded.error == nil ? decoded.text : value)
                                .font(AppFont.dataCell)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(AppSpacing.large)
                        }
                    }
                    .contextMenu {
                        Button("Copy Value") {
                            copyToPasteboard(value)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button("Edit Value", systemImage: "square.and.pencil") {
                            editValue = value
                            isEditing = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(IconButtonStyle(weight: .semibold))
                        .help("Edit value")
                        .padding(AppSpacing.large)
                    }

                    Divider()

                    PanelFooterBar {
                        OptionsPicker(
                            "Value format",
                            selection: $format,
                            options: StringValueFormat.allCases,
                            label: \.title
                        )

                        Spacer()

                        Button("Import File", systemImage: "square.and.arrow.down") {
                            isImporting = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(IconButtonStyle())
                        .disabled(isEditing)
                        .help("Replace the value with a file's contents")

                        Button("Export File", systemImage: "square.and.arrow.up") {
                            exportDocument = TextExportDocument(text: value, defaultFilename: exportFilename)
                            isExporting = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(IconButtonStyle())
                        .disabled(isEditing)
                        .help("Save the value to a file")
                    }
                }
            }

        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportDocument?.defaultFilename
        ) { _ in }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            importFromFile(result)
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    /// Suggested export filename: the key's last namespace segment, with
    /// path separators replaced so the save dialog always gets a valid name.
    private var exportFilename: String {
        let leaf = key.split(separator: ":").last.map(String.init) ?? key
        let sanitized = leaf.replacingOccurrences(of: "/", with: "_")
        return sanitized.isEmpty ? "value.txt" : "\(sanitized).txt"
    }

    private func importFromFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importError = "Could not read \(url.lastPathComponent)."
            return
        }
        guard data.count <= Self.importSizeLimit else {
            importError = "File exceeds the 10 MB import limit."
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            importError = "File is not valid UTF-8 text."
            return
        }
        onSave(text)
    }
}

private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.focusRingType = .none
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: PlainTextEditor

        init(_ parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
