import Foundation

// MARK: - String Value Formatter

/// Pure value formatting for string-ish Redis values, shared by the string
/// detail view and the collection member viewer. Framework-free on purpose:
/// no SwiftUI, no session state — `String` in, decoded text out.
enum StringValueFormatter {
    struct Decoded {
        let text: String
        let error: String?
    }

    /// Parse + pretty-print once. Callers must not re-parse the (up to 1 MB)
    /// value multiple times per body evaluation.
    static func prettyPrintedJSON(_ value: String) -> String? {
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
    static func decoded(_ value: String, format: StringValueFormat) -> Decoded {
        switch format {
        case .raw:
            return Decoded(text: value, error: nil)
        case .unicode:
            return Decoded(text: unicodeEscaped(value), error: nil)
        case .json:
            // JSON pretty-printing is handled by `prettyPrintedJSON`; a
            // non-JSON value falls back to raw here.
            return Decoded(text: value, error: nil)
        case .ascii:
            return Decoded(text: ascii(value), error: nil)
        case .hex:
            return Decoded(text: hexString(value), error: nil)
        case .base64:
            guard let data = Data(base64Encoded: value) else {
                return Decoded(text: value, error: "Invalid Base64 data — showing the raw value.")
            }
            guard let decoded = String(data: data, encoding: .utf8) else {
                return Decoded(text: value, error: "Base64 data is not valid UTF-8 — showing the raw value.")
            }
            return Decoded(text: decoded, error: nil)
        case .base64Encode:
            guard let data = value.data(using: .utf8) else {
                return Decoded(text: value, error: nil)
            }
            return Decoded(text: data.base64EncodedString(), error: nil)
        case .msgpack:
            guard let data = value.data(using: .utf8) else {
                return Decoded(text: value, error: "Value is not decodable as UTF-8 bytes.")
            }
            do {
                let object = try MessagePackDecoder.decode(data)
                let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                guard let text = String(data: pretty, encoding: .utf8) else {
                    return Decoded(text: value, error: "MessagePack decoded to non-UTF-8 output.")
                }
                return Decoded(text: text, error: nil)
            } catch {
                return Decoded(
                    text: value,
                    error: "Not valid MessagePack (values are read as UTF-8 bytes, so binary payloads may be mangled)."
                )
            }
        case .gzip:
            guard let data = Data(base64Encoded: value) ?? value.data(using: .utf8) else {
                return Decoded(text: value, error: "Unable to read data — showing the raw value.")
            }
            guard !data.isEmpty else { return Decoded(text: value, error: nil) }
            guard let decompressed = gunzip(data) else {
                return Decoded(text: value, error: "GZip decompression failed — showing the raw value.")
            }
            guard let decoded = String(data: decompressed, encoding: .utf8) else {
                return Decoded(text: value, error: "Decompressed data is not valid UTF-8 — showing the raw value.")
            }
            return Decoded(text: decoded, error: nil)
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

    /// Inflates one gzip member (RFC 1952). `NSData` offers `.zlib` but no `.gzip`
    /// algorithm; it does accept the raw deflate stream, so this validates the
    /// header, skips the optional fields selected by the flags, and inflates the
    /// body between them and the 8-byte trailer. Returns nil for anything that is
    /// not a single gzip member (including zlib streams and plain text), so
    /// callers fall back to the raw value.
    private static func gunzip(_ data: Data) -> Data? {
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
}
