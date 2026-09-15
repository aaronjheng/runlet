import Foundation
import Network

// MARK: - RESP Protocol Version

enum RESPProtocolVersion: Sendable {
    case resp2
    case resp3

    var helloArgument: String {
        switch self {
        case .resp2: return "2"
        case .resp3: return "3"
        }
    }

    var logName: String {
        switch self {
        case .resp2: return "RESP2"
        case .resp3: return "RESP3"
        }
    }
}

// MARK: - RESP Map Entry (for RESP3 maps)

struct RESPMapEntry: Sendable {
    let key: RESPValue
    let value: RESPValue
}

// MARK: - RESP2/RESP3 Protocol Parser

enum RESPValue: CustomStringConvertible, Sendable {
    case simpleString(String)
    case error(String)
    case integer(Int)
    case bulkString(String?)
    case array([RESPValue?])
    case map([RESPMapEntry])
    case null
    case boolean(Bool)
    case double(Double)

    var description: String {
        switch self {
        case .simpleString(let string): return string
        case .error(let message): return "(error) \(message)"
        case .integer(let integer): return "(integer) \(integer)"
        case .bulkString(let string): return string ?? "(nil)"
        case .array(let values):
            return values.enumerated().map { index, value in
                "\(index + 1)) \(value?.description ?? "(nil)")"
            }.joined(separator: "\n")
        case .map(let entries):
            return entries.map { entry in
                "\(entry.key.description): \(entry.value.description)"
            }.joined(separator: "\n")
        case .null: return "(nil)"
        case .boolean(let value): return value ? "true" : "false"
        case .double(let value): return String(value)
        }
    }

    var displayString: String {
        switch self {
        case .simpleString(let string): return string
        case .error(let message): return "ERR \(message)"
        case .integer(let integer): return "\(integer)"
        case .bulkString(let string): return string ?? "(nil)"
        case .array(let values):
            guard !values.isEmpty else { return "(empty array)" }
            return values.enumerated().map { index, value in
                let content = value?.displayString ?? "(nil)"
                return "\(index + 1)) \(content)"
            }.joined(separator: "\n")
        case .map(let entries):
            guard !entries.isEmpty else { return "(empty map)" }
            return entries.map { entry in
                "\(entry.key.displayString): \(entry.value.displayString)"
            }.joined(separator: "\n")
        case .null: return "(nil)"
        case .boolean(let value): return value ? "true" : "false"
        case .double(let value): return String(value)
        }
    }

    var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    var arrayValues: [RESPValue?] {
        if case .array(let values) = self { return values }
        return []
    }

    var keyValuePairs: [(key: RESPValue, value: RESPValue)] {
        switch self {
        case .array(let values):
            var pairs: [(key: RESPValue, value: RESPValue)] = []
            var index = 0
            while index + 1 < values.count {
                if let key = values[index], let value = values[index + 1] {
                    pairs.append((key: key, value: value))
                }
                index += 2
            }
            return pairs
        case .map(let entries):
            return entries.map { (key: $0.key, value: $0.value) }
        default:
            return []
        }
    }

    var string: String? {
        switch self {
        case .simpleString(let string): return string
        case .bulkString(let string): return string
        default: return nil
        }
    }

    var intValue: Int? {
        if case .integer(let integer) = self { return integer }
        return nil
    }
}

// MARK: - RESP Parsed Message

enum RESPMessage: Sendable {
    case response(RESPValue)
    case push(RESPValue)
}

/// A hard protocol violation: the buffered bytes can never form a valid RESP
/// value, so waiting for more data would hang forever. The connection must be
/// treated as desynchronized.
enum RESPParseError: Error, Sendable {
    case protocolViolation(String)
}

struct RESPParser: Sendable {
    private var buffer = Data()
    private var readIndex: Data.Index = 0
    let maxBulkBytes: Int
    let maxAggregateCount: Int
    let maxDepth: Int

    init(
        maxBulkBytes: Int = 512 * 1024 * 1024,
        maxAggregateCount: Int = 1_000_000,
        maxDepth: Int = 64
    ) {
        self.maxBulkBytes = maxBulkBytes
        self.maxAggregateCount = maxAggregateCount
        self.maxDepth = maxDepth
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Drop bytes that have already been consumed by `parse()`, keeping only
    /// the trailing fragment that is not yet a complete RESP value.
    mutating func compact() {
        guard readIndex > buffer.startIndex else { return }
        buffer.removeSubrange(buffer.startIndex..<readIndex)
        readIndex = buffer.startIndex
    }

    /// Parse a single complete top-level RESP value, if one is fully buffered.
    ///
    /// Returns `nil` when the buffered data does not yet contain a complete
    /// value. Throws `RESPParseError` when the buffered data is malformed —
    /// the caller must not keep waiting, since more bytes can never fix it.
    mutating func parse() throws -> RESPMessage? {
        guard readIndex < buffer.endIndex else { return nil }
        let start = readIndex
        let firstByte = buffer[readIndex]

        // RESP3 push frames ('>') are unsolicited and must not be matched
        // against an in-flight request, so they are surfaced separately.
        if firstByte == 0x3E {
            guard let value = try parseValue(depth: 0) else {
                readIndex = start
                return nil
            }
            return .push(value)
        }

        guard let value = try parseValue(depth: 0) else {
            readIndex = start
            return nil
        }
        return .response(value)
    }

    private mutating func parseValue(depth: Int) throws -> RESPValue? {
        guard readIndex < buffer.endIndex else { return nil }
        guard depth <= maxDepth else {
            throw RESPParseError.protocolViolation("RESP nesting exceeds maximum depth \(maxDepth)")
        }

        let firstByte = buffer[readIndex]
        switch firstByte {
        case 0x2B:  // '+'
            return try parseSimpleString()
        case 0x2D:  // '-'
            return try parseError()
        case 0x3A:  // ':'
            return try parseInteger()
        case 0x24:  // '$'
            return try parseBulkString()
        case 0x2A:  // '*'
            return try parseArray(depth: depth)
        case 0x5F:  // '_'
            return try parseNull()
        case 0x23:  // '#'
            return try parseBoolean()
        case 0x2C:  // ','
            return try parseDouble()
        case 0x28:  // '('
            return try parseBigNumber()
        case 0x21:  // '!'
            return try parseBlobError()
        case 0x3D:  // '='
            return try parseVerbatimString()
        case 0x25:  // '%'
            return try parseMap(depth: depth)
        case 0x7E:  // '~'
            return try parseSet(depth: depth)
        case 0x3E:  // '>'
            return try parsePush(depth: depth)
        case 0x7C:  // '|'
            return try parseAttribute(depth: depth)
        default:
            throw RESPParseError.protocolViolation("Unknown RESP type byte 0x\(String(firstByte, radix: 16))")
        }
    }

    private mutating func readLine() throws -> String? {
        var search = readIndex
        while search < buffer.endIndex {
            if buffer[search] == 0x0D {
                let lineFeedIndex = buffer.index(after: search)
                if lineFeedIndex >= buffer.endIndex {
                    return nil  // CRLF may still be split across chunks
                }
                guard buffer[lineFeedIndex] == 0x0A else {
                    throw RESPParseError.protocolViolation("Line terminator is not CRLF")
                }
                let lineData = buffer[readIndex..<search]
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw RESPParseError.protocolViolation("Header line is not valid UTF-8")
                }
                readIndex = buffer.index(after: lineFeedIndex)
                return line
            }
            search = buffer.index(after: search)
        }
        return nil
    }

    private mutating func parseSimpleString() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '+'
        guard let line = try readLine() else { return nil }
        return .simpleString(line)
    }

    private mutating func parseError() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '-'
        guard let line = try readLine() else { return nil }
        return .error(line)
    }

    private mutating func parseInteger() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove ':'
        guard let line = try readLine() else { return nil }
        guard let val = Int(line) else {
            throw RESPParseError.protocolViolation("Invalid integer line \(line)")
        }
        return .integer(val)
    }

    private mutating func parseBulkString() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '$'
        guard let line = try readLine(), let len = Int(line) else { return nil }
        if len == -1 { return .bulkString(nil) }
        guard let string = try readPayload(length: len) else { return nil }
        return .bulkString(string)
    }

    private mutating func parseArray(depth: Int) throws -> RESPValue? {
        guard let items = try parseAggregateItems(depth: depth) else { return nil }
        return .array(items)
    }

    private mutating func parseNull() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '_'
        guard try readLine() == "" else {
            throw RESPParseError.protocolViolation("Malformed null frame")
        }
        return .null
    }

    private mutating func parseBoolean() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '#'
        guard let line = try readLine() else { return nil }
        switch line {
        case "t": return .boolean(true)
        case "f": return .boolean(false)
        default:
            throw RESPParseError.protocolViolation("Invalid boolean value \(line)")
        }
    }

    private mutating func parseDouble() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove ','
        guard let line = try readLine() else { return nil }
        switch line.lowercased() {
        case "inf": return .double(.infinity)
        case "-inf": return .double(-.infinity)
        case "nan": return .double(.nan)
        default:
            guard let value = Double(line) else {
                throw RESPParseError.protocolViolation("Invalid double value \(line)")
            }
            return .double(value)
        }
    }

    private mutating func parseBigNumber() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '('
        guard let line = try readLine() else { return nil }
        return .bulkString(line)
    }

    private mutating func parseBlobError() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '!'
        guard let line = try readLine(), let len = Int(line) else { return nil }
        guard let message = try readPayload(length: len) else { return nil }
        return .error(message)
    }

    private mutating func parseVerbatimString() throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '='
        guard let line = try readLine(), let len = Int(line) else { return nil }
        guard let string = try readPayload(length: len) else { return nil }
        guard string.count >= 4 else { return .bulkString(string) }
        return .bulkString(String(string.dropFirst(4)))
    }

    private mutating func parseMap(depth: Int) throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '%'
        guard let line = try readLine(), let count = Int(line) else { return nil }
        if count == -1 { return .null }
        if count == 0 { return .map([]) }
        guard count > 0 else {
            throw RESPParseError.protocolViolation("Invalid map count \(count)")
        }
        guard count <= maxAggregateCount else {
            throw RESPParseError.protocolViolation("Map size \(count) exceeds limit \(maxAggregateCount)")
        }
        var entries: [RESPMapEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard let key = try parseValue(depth: depth + 1), let value = try parseValue(depth: depth + 1) else {
                return nil
            }
            entries.append(RESPMapEntry(key: key, value: value))
        }
        return .map(entries)
    }

    private mutating func parseSet(depth: Int) throws -> RESPValue? {
        guard let items = try parseAggregateItems(depth: depth) else { return nil }
        return .array(items)
    }

    private mutating func parsePush(depth: Int) throws -> RESPValue? {
        guard let items = try parseAggregateItems(depth: depth) else { return nil }
        return .array(items)
    }

    /// Parse a RESP3 attribute (`|`) and return the next value.
    ///
    /// RESP3 attributes are metadata attached to the immediately following
    /// value. The current implementation skips the attribute key/value pairs
    /// and returns the next value. A future improvement could surface the
    /// attribute data as part of the RESPValue type.
    private mutating func parseAttribute(depth: Int) throws -> RESPValue? {
        readIndex = buffer.index(after: readIndex)  // remove '|'
        guard let line = try readLine(), let count = Int(line), count >= 0 else {
            throw RESPParseError.protocolViolation("Invalid attribute count")
        }
        guard count <= maxAggregateCount else {
            throw RESPParseError.protocolViolation("Attribute size \(count) exceeds limit \(maxAggregateCount)")
        }
        for _ in 0..<count {
            guard try parseValue(depth: depth + 1) != nil, try parseValue(depth: depth + 1) != nil else {
                return nil
            }
        }
        // Return the next value (the one the attribute annotates)
        return try parseValue(depth: depth)
    }

    private mutating func parseAggregateItems(depth: Int) throws -> [RESPValue?]? {
        readIndex = buffer.index(after: readIndex)  // remove prefix byte
        guard let line = try readLine(), let count = Int(line), count >= -1 else {
            throw RESPParseError.protocolViolation("Invalid aggregate count")
        }
        if count == -1 { return [] }
        if count == 0 { return [] }
        guard count <= maxAggregateCount else {
            throw RESPParseError.protocolViolation("Aggregate size \(count) exceeds limit \(maxAggregateCount)")
        }
        var items: [RESPValue?] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            guard let val = try parseValue(depth: depth + 1) else {
                return nil
            }
            items.append(val)
        }
        return items
    }

    private mutating func readPayload(length: Int) throws -> String? {
        guard length >= 0 else {
            throw RESPParseError.protocolViolation("Invalid bulk length \(length)")
        }
        guard length <= maxBulkBytes else {
            throw RESPParseError.protocolViolation("Bulk length \(length) exceeds limit \(maxBulkBytes)")
        }
        let remaining = buffer.distance(from: readIndex, to: buffer.endIndex)
        guard remaining >= length + 2 else { return nil }

        let payloadEndIndex = buffer.index(readIndex, offsetBy: length)
        let lineFeedIndex = buffer.index(after: payloadEndIndex)
        guard buffer[payloadEndIndex] == 0x0D, buffer[lineFeedIndex] == 0x0A else {
            throw RESPParseError.protocolViolation("Bulk payload is not terminated by CRLF")
        }

        let payloadData = buffer[readIndex..<payloadEndIndex]
        readIndex = buffer.index(after: lineFeedIndex)
        // Lossy decode keeps binary values inspectable instead of silently
        // collapsing them to an empty string; invalid bytes become U+FFFD.
        return String(decoding: payloadData, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
    }
}

// MARK: - RESP Encoder

struct RESPEncoder {
    static func encode(_ args: [String]) -> Data {
        encode(args, version: .resp2)
    }

    static func encode(_ args: [String], version: RESPProtocolVersion) -> Data {
        var data = Data()
        data.append(contentsOf: "*\(args.count)\r\n".utf8)
        for arg in args {
            let bytes = Data(arg.utf8)
            data.append(contentsOf: "$\(bytes.count)\r\n".utf8)
            data.append(bytes)
            data.append(contentsOf: "\r\n".utf8)
        }
        return data
    }
}
