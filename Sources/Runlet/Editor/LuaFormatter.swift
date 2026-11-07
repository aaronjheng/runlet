import Foundation

/// Native Lua formatting behind the Functions editor's ⌥⇧F: StyLua
/// statically linked into the app from `Sources/StyLua` (see BUILD-INFO.md -
/// no Lua runtime is involved). The shim crate exports this one C ABI
/// pair, and the bindings below pin its exact shape for Swift. Input and
/// output are plain UTF-8 text; a library that does not parse throws
/// instead of being guessed at, so the editor keeps the user's text
/// untouched.
enum LuaFormatter {
    /// The parser refused the library.
    struct LuaFormatError: Error, Sendable {
        /// The diagnostic, e.g. "error parsing: unexpected token ...".
        var message: String
    }

    /// Mirror of the shim's C-repr `RunletBuffer`; field order matters.
    /// `data` is raw UTF-8, not NUL-terminated; `len` is exact in bytes.
    private struct RunletBuffer {
        var data: UnsafeMutableRawPointer?
        var len: Int
    }

    /// Mirror of the shim's C-repr `RunletFormatResult`; field order
    /// matters. The shim zeroes both buffers first, so they are readable
    /// on every status.
    private struct RunletFormatResult {
        var out: RunletBuffer
        var err: RunletBuffer
    }

    /// Formats Lua source text. Returns:
    /// - `0` and fills `result.out` with the formatted code,
    /// - `1` and fills `result.err` with a diagnostic message when the
    ///   input did not parse (the app surfaces it and keeps the text),
    /// - `2` when the input is not valid UTF-8,
    /// - `-1` on usage errors (null input or result pointer).
    ///
    /// Lengths are `usize` (LP64, matching Swift's `Int`); buffers are
    /// released via `runletStrFree` with the exact pointer/length pair
    /// handed out.
    @_silgen_name("runlet_format_lua")
    private static func runletFormatLua(
        _ input: UnsafePointer<UInt8>?,
        _ inputLen: Int,
        _ result: UnsafeMutablePointer<RunletFormatResult>
    ) -> Int32

    /// Releases a buffer handed out by `runletFormatLua`; same pointer and
    /// length it returned, both required.
    @_silgen_name("runlet_str_free")
    private static func runletStrFree(_ ptr: UnsafeMutableRawPointer?, _ len: Int)

    /// Formats `source`. Returns `nil` when the library is already
    /// formatted - a no-op that leaves the editor's undo stack clean
    /// instead of pushing a zero-diff entry. Throws `LuaFormatError`
    /// when the input does not parse.
    static func format(_ source: String) throws -> String? {
        if source.isEmpty { return nil }
        // The engine takes UTF-8 bytes and hands back UTF-8 bytes; library
        // scripts are small (a few KB), so the one-shot copies are nothing.
        let utf8 = Array(source.utf8)
        return try utf8.withUnsafeBufferPointer { bytes in
            var result = RunletFormatResult(
                out: RunletBuffer(data: nil, len: 0),
                err: RunletBuffer(data: nil, len: 0))
            let status = runletFormatLua(bytes.baseAddress, bytes.count, &result)
            if status == 0 {
                defer { runletStrFree(result.out.data, result.out.len) }
                let buffer = UnsafeRawBufferPointer(start: result.out.data, count: result.out.len)
                guard let code = String(bytes: buffer, encoding: .utf8) else {
                    throw LuaFormatError(message: "Formatter returned invalid UTF-8")
                }
                return code == source ? nil : code
            }
            var message = "Invalid Lua"
            if result.err.len > 0, let errData = result.err.data {
                defer { runletStrFree(errData, result.err.len) }
                let buffer = UnsafeRawBufferPointer(start: errData, count: result.err.len)
                message = String(bytes: buffer, encoding: .utf8) ?? message
            }
            throw LuaFormatError(message: message)
        }
    }
}
