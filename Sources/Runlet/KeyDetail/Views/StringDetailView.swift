import AppKit
import SwiftUI

// MARK: - String Detail View

struct StringDetailView: View {
    let key: String
    let value: String
    @Binding var format: StringValueFormat
    let onSave: (String) -> Void

    @State private var isEditing = false
    @State private var editValue = ""

    private var isJson: Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private var beautifiedValue: String {
        guard
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return value
        }
        return prettyString
    }

    private var displayedValue: String {
        switch format {
        case .raw:
            return value
        case .unicode:
            return unicodeEscapedValue
        case .json:
            return isJson ? beautifiedValue : value
        case .ascii:
            return asciiValue
        case .hex:
            return hexValue
        case .base64:
            return base64DecodedValue
        case .base64Encode:
            return base64EncodedValue
        case .gzip:
            return gzipDecompressedValue
        }
    }

    private var unicodeEscapedValue: String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0A:
                return "\\n"
            case 0x0D:
                return "\\r"
            case 0x09:
                return "\\t"
            case 0x20...0x7E:
                return String(scalar)
            default:
                return "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }.joined()
    }

    private var asciiValue: String {
        String(
            value.utf8.map { byte in
                if (32...126).contains(byte), let scalar = UnicodeScalar(Int(byte)) {
                    return Character(scalar)
                }
                return "."
            }
        )
    }

    private var hexValue: String {
        value.utf8.enumerated().map { index, byte in
            let separator = index > 0 && index % 16 == 0 ? "\n" : " "
            let prefix = index == 0 ? "" : separator
            return prefix + String(format: "%02X", byte)
        }.joined()
    }

    private var base64DecodedValue: String {
        guard let data = Data(base64Encoded: value),
            let decoded = String(data: data, encoding: .utf8)
        else {
            return value
        }
        return decoded
    }

    private var base64EncodedValue: String {
        guard let data = value.data(using: .utf8) else {
            return value
        }
        return data.base64EncodedString()
    }

    private var gzipDecompressedValue: String {
        guard let data = Data(base64Encoded: value) ?? value.data(using: .utf8) else {
            return value
        }
        guard !data.isEmpty else { return value }
        do {
            let decompressed = try (data as NSData).decompressed(using: .zlib) as Data
            return String(data: decompressed, encoding: .utf8) ?? value
        } catch {
            return value
        }
    }

    /// Why the current format cannot decode `value`, if any. Shown in an
    /// `ErrorBanner` above the raw value so decode failures are never
    /// mistaken for the actual stored value.
    private var decodeError: String? {
        switch format {
        case .base64:
            guard let data = Data(base64Encoded: value) else {
                return "Invalid Base64 data — showing the raw value."
            }
            guard String(data: data, encoding: .utf8) != nil else {
                return "Base64 data is not valid UTF-8 — showing the raw value."
            }
            return nil
        case .gzip:
            guard let data = Data(base64Encoded: value) ?? value.data(using: .utf8) else {
                return "Unable to read data — showing the raw value."
            }
            guard !data.isEmpty else { return nil }
            do {
                let decompressed = try (data as NSData).decompressed(using: .zlib) as Data
                guard String(data: decompressed, encoding: .utf8) != nil else {
                    return "Decompressed data is not valid UTF-8 — showing the raw value."
                }
                return nil
            } catch {
                return "GZip decompression failed — showing the raw value."
            }
        default:
            return nil
        }
    }

    var body: some View {
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
                                .stroke(Color.accentColor, lineWidth: 2)
                        )

                    HStack(spacing: AppSpacing.small) {
                        Spacer()
                        Button("Cancel") {
                            isEditing = false
                        }
                        .buttonStyle(.borderless)
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
                        if format == .json && isJson {
                            SelectableText(
                                text: beautifiedValue,
                                font: AppFont.dataCellNSFont,
                                tokenizer: TreeSitterJsonHighlighter.shared
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppSpacing.large)
                        } else {
                            if let decodeError {
                                ErrorBanner(message: decodeError)
                            }
                            Text(decodeError == nil ? displayedValue : value)
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
                    }
                }
            }

        }
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
        textView.focusRingType = .default
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
