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

    /// Parse + pretty-print once. The old `isJson`/`beautifiedValue` pair
    /// parsed the (up to 1 MB) value 2–3× per body evaluation; callers compute
    /// this once per body and share it.
    private static func prettyPrintedJSON(_ value: String) -> String? {
        guard
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return prettyString
    }

    /// Decoded text + failure reason computed together, so Base64/GZip inputs
    /// are decoded once per body instead of once for the error banner and
    /// again for the displayed text.
    private struct DecodedValue {
        let text: String
        let error: String?
    }

    private static func decodedValue(_ value: String, format: StringValueFormat) -> DecodedValue {
        switch format {
        case .raw:
            return DecodedValue(text: value, error: nil)
        case .unicode:
            return DecodedValue(text: unicodeEscaped(value), error: nil)
        case .json:
            // JSON pretty-printing is handled by `prettyPrintedJSON`; a
            // non-JSON value falls back to raw here.
            return DecodedValue(text: value, error: nil)
        case .ascii:
            return DecodedValue(text: ascii(value), error: nil)
        case .hex:
            return DecodedValue(text: hexString(value), error: nil)
        case .base64:
            guard let data = Data(base64Encoded: value) else {
                return DecodedValue(text: value, error: "Invalid Base64 data — showing the raw value.")
            }
            guard let decoded = String(data: data, encoding: .utf8) else {
                return DecodedValue(text: value, error: "Base64 data is not valid UTF-8 — showing the raw value.")
            }
            return DecodedValue(text: decoded, error: nil)
        case .base64Encode:
            guard let data = value.data(using: .utf8) else {
                return DecodedValue(text: value, error: nil)
            }
            return DecodedValue(text: data.base64EncodedString(), error: nil)
        case .gzip:
            guard let data = Data(base64Encoded: value) ?? value.data(using: .utf8) else {
                return DecodedValue(text: value, error: "Unable to read data — showing the raw value.")
            }
            guard !data.isEmpty else { return DecodedValue(text: value, error: nil) }
            guard let decompressed = gunzip(data) else {
                return DecodedValue(text: value, error: "GZip decompression failed — showing the raw value.")
            }
            guard let decoded = String(data: decompressed, encoding: .utf8) else {
                return DecodedValue(text: value, error: "Decompressed data is not valid UTF-8 — showing the raw value.")
            }
            return DecodedValue(text: decoded, error: nil)
        }
    }

    private static func unicodeEscaped(_ value: String) -> String {
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

    private static func ascii(_ value: String) -> String {
        String(
            value.utf8.map { byte in
                if (32...126).contains(byte), let scalar = UnicodeScalar(Int(byte)) {
                    return Character(scalar)
                }
                return "."
            }
        )
    }

    /// Hex digit pairs without per-byte `String(format:)` (which parses the
    /// format string for every byte of the value).
    private static let hexByteStrings: [String] = (UInt8.min...UInt8.max).map { String(format: "%02X", $0) }

    private static func hexString(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var parts: [String] = []
        parts.reserveCapacity(bytes.count)
        for (index, byte) in bytes.enumerated() {
            let separator = index == 0 ? "" : (index % 16 == 0 ? "\n" : " ")
            parts.append(separator + hexByteStrings[Int(byte)])
        }
        return parts.joined()
    }

    var body: some View {
        // Parse/transform once per body: the JSON branch needs the pretty
        // string, every other branch needs exactly one decode pass.
        let jsonPretty = format == .json ? Self.prettyPrintedJSON(value) : nil
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
                            let decoded = Self.decodedValue(value, format: format)
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
                    }
                }
            }

        }
    }
}

/// Inflates one gzip member (RFC 1952). `NSData` offers `.zlib` but no `.gzip`
/// algorithm; it does accept the raw deflate stream, so this validates the
/// header, skips the optional fields selected by the flags, and inflates the
/// body between them and the 8-byte trailer. Returns nil for anything that is
/// not a single gzip member (including zlib streams and plain text), so
/// callers fall back to the raw value.
private func gunzip(_ data: Data) -> Data? {
    guard data.count > 18 else { return nil }
    let bytes = [UInt8](data)
    guard bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else { return nil }
    let flags = bytes[3]
    guard flags & 0xE0 == 0 else { return nil }
    var pos = 10
    if flags & 0x04 != 0 {
        guard pos + 2 <= bytes.count else { return nil }
        pos += 2 + Int(bytes[pos]) + (Int(bytes[pos + 1]) << 8)
    }
    if flags & 0x08 != 0 {
        guard let end = bytes[pos...].firstIndex(of: 0) else { return nil }
        pos = end + 1
    }
    if flags & 0x10 != 0 {
        guard let end = bytes[pos...].firstIndex(of: 0) else { return nil }
        pos = end + 1
    }
    if flags & 0x02 != 0 {
        pos += 2
    }
    guard pos + 8 <= bytes.count else { return nil }
    let body = data[pos..<(bytes.count - 8)]
    return try? (body as NSData).decompressed(using: .zlib) as Data
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
