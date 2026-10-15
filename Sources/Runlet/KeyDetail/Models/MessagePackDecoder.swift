import Foundation

// MARK: - MessagePack Decoder

/// Minimal MessagePack reader that maps values onto JSON-serializable
/// Foundation types (dictionary/array/String/NSNumber/Bool/NSNull) so the
/// result can be pretty-printed with `JSONSerialization`.
///
/// Binary (`bin`) payloads render as Base64 strings; extension types render
/// as a descriptive string carrying their type byte and hex body. Well-known
/// extensions such as the MessagePack timestamp are not interpreted.
enum MessagePackDecoder {
    enum Failure: Swift.Error {
        case truncated
        case unsupported
    }

    static func decode(_ data: Data) throws -> Any {
        var reader = Reader(bytes: [UInt8](data))
        let value = try reader.readValue()
        guard reader.offset == reader.bytes.count else { throw Failure.unsupported }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func readValue() throws -> Any {
            guard let byte = readByte() else { throw Failure.truncated }
            switch byte {
            case 0x00...0x7F:
                return NSNumber(value: Int(byte))
            case 0xE0...0xFF:
                return NSNumber(value: Int(Int8(bitPattern: byte)))
            case 0x80...0x8F:
                return try readMap(count: Int(byte & 0x0F))
            case 0x90...0x9F:
                return try readArray(count: Int(byte & 0x0F))
            case 0xA0...0xBF:
                return try readString(count: Int(byte & 0x1F))
            case 0xC0:
                return NSNull()
            case 0xC2:
                return false
            case 0xC3:
                return true
            case 0xC4, 0xC5, 0xC6:
                return try readBinary(count: try readLength(threeStepBase: 0xC4, byte: byte))
            case 0xC7, 0xC8, 0xC9:
                return try readExtension(length: try readLength(threeStepBase: 0xC7, byte: byte))
            case 0xCA:
                return try readFloat(byteCount: 4)
            case 0xCB:
                return try readFloat(byteCount: 8)
            case 0xCC...0xCF:
                return try readUnsigned(byteCount: 1 << (byte - 0xCC))
            case 0xD0...0xD3:
                return try readSigned(byteCount: 1 << (byte - 0xD0))
            case 0xD4...0xD8:
                return try readExtension(length: 1 << (byte - 0xD4))
            case 0xD9...0xDB:
                return try readString(count: try readLength(threeStepBase: 0xD9, byte: byte))
            case 0xDC, 0xDD:
                return try readArray(count: try readLength(twoStepBase: 0xDC, byte: byte))
            case 0xDE, 0xDF:
                return try readMap(count: try readLength(twoStepBase: 0xDE, byte: byte))
            default:
                throw Failure.unsupported
            }
        }

        // MARK: Length headers

        /// 8/16/32-bit length families (`str`, `bin`, `ext`).
        private mutating func readLength(threeStepBase base: UInt8, byte: UInt8) throws -> Int {
            switch byte - base {
            case 0:
                return Int(try readRequiredByte())
            case 1:
                return Int(try readFixedUnsigned(byteCount: 2))
            case 2:
                return Int(try readFixedUnsigned(byteCount: 4))
            default:
                throw Failure.unsupported
            }
        }

        /// 16/32-bit length families (`array16/32`, `map16/32`).
        private mutating func readLength(twoStepBase base: UInt8, byte: UInt8) throws -> Int {
            switch byte - base {
            case 0:
                return Int(try readFixedUnsigned(byteCount: 2))
            case 1:
                return Int(try readFixedUnsigned(byteCount: 4))
            default:
                throw Failure.unsupported
            }
        }

        // MARK: Scalars

        private mutating func readByte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        private mutating func readRequiredByte() throws -> UInt8 {
            guard let byte = readByte() else { throw Failure.truncated }
            return byte
        }

        private mutating func readFixedUnsigned(byteCount: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<byteCount {
                let byte = try readRequiredByte()
                value = (value << 8) | UInt64(byte)
            }
            return value
        }

        private mutating func readUnsigned(byteCount: Int) throws -> Any {
            NSNumber(value: try readFixedUnsigned(byteCount: byteCount))
        }

        private mutating func readSigned(byteCount: Int) throws -> Any {
            let raw = try readFixedUnsigned(byteCount: byteCount)
            let value: Int64
            switch byteCount {
            case 1:
                value = Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
            case 2:
                value = Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
            case 4:
                value = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
            default:
                value = Int64(bitPattern: raw)
            }
            return NSNumber(value: value)
        }

        private mutating func readFloat(byteCount: Int) throws -> Any {
            let raw = try readFixedUnsigned(byteCount: byteCount)
            if byteCount == 4 {
                return NSNumber(value: Float32(bitPattern: UInt32(truncatingIfNeeded: raw)))
            }
            return NSNumber(value: Float64(bitPattern: raw))
        }

        // MARK: Compound payloads

        private mutating func readString(count: Int) throws -> Any {
            guard offset + count <= bytes.count else { throw Failure.truncated }
            defer { offset += count }
            // `str` is UTF-8 by spec; stay lenient so one malformed string
            // does not fail the whole document — fall back to Base64 of the
            // raw bytes instead of failing.
            let chunk = Data(bytes[offset..<offset + count])
            return String(data: chunk, encoding: .utf8) ?? chunk.base64EncodedString()
        }

        private mutating func readBinary(count: Int) throws -> Any {
            guard offset + count <= bytes.count else { throw Failure.truncated }
            defer { offset += count }
            return Data(bytes[offset..<offset + count]).base64EncodedString()
        }

        private mutating func readExtension(length: Int) throws -> Any {
            let type = try readRequiredByte()
            guard offset + length <= bytes.count else { throw Failure.truncated }
            defer { offset += length }
            let hex = bytes[offset..<offset + length].map { String(format: "%02x", $0) }.joined()
            return "ext(type=\(type)) \(hex)"
        }

        private mutating func readArray(count: Int) throws -> Any {
            var result: [Any] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                result.append(try readValue())
            }
            return result
        }

        private mutating func readMap(count: Int) throws -> Any {
            var result: [String: Any] = [:]
            result.reserveCapacity(count)
            for _ in 0..<count {
                let key = try readValue()
                let value = try readValue()
                result[keyString(key)] = value
            }
            return result
        }

        /// JSON objects need string keys; describe non-string MessagePack keys
        /// instead of failing the whole document.
        private func keyString(_ value: Any) -> String {
            switch value {
            case let string as String:
                return string
            case is NSNull:
                return "nil"
            case let bool as Bool where type(of: value) == Bool.self:
                return bool ? "true" : "false"
            case let number as NSNumber:
                return number.stringValue
            default:
                return "\(value)"
            }
        }
    }
}
