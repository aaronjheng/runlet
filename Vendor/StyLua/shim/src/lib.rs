//! C-ABI shim exposing StyLua (the Lua formatter) to the Runlet macOS app
//! as a native static library - no Lua runtime involved.

use std::os::raw::c_char;
use std::slice;

use stylua_lib::{Config, IndentType, LuaVersion, OutputVerification, QuoteStyle, format_code};

/// Formats Lua source text. Returns:
/// - `0` and fills `out_data`/`out_len` with the formatted code on success,
/// - `1` and fills `err_data`/`err_len` with a diagnostic message when the
///   input did not parse (or formatting failed),
/// - `2` when the input is not valid UTF-8,
/// - `-1` on usage errors (null out pointers).
///
/// Result buffers are heap-owned strings released via `runlet_str_free(ptr,
/// len)`. They are raw UTF-8 bytes, not NUL-terminated.
pub fn format_text(source: &str) -> Result<String, String> {
    // Redis function libraries run Lua 5.1; formatting pins that grammar so
    // 5.2+ syntax is refused rather than silently reformatted. The rest
    // matches the project's editor conventions: 2-space indent (Plume's
    // indent unit), width 100 (Canoe's Oxfmt line width), single quotes
    // preferred (the template and most Redis Lua samples use them), call
    // parentheses always (redis.call("GET", key) style). Output is verified
    // by reparsing, so a formatter bug can never silently corrupt a
    // library.
    let config = Config {
        syntax: LuaVersion::Lua51,
        column_width: 100,
        indent_type: IndentType::Spaces,
        indent_width: 2,
        quote_style: QuoteStyle::AutoPreferSingle,
        ..Config::default()
    };
    format_code(source, config, None, OutputVerification::Full)
        .map_err(|error| error.to_string())
}

/// One handed-out UTF-8 buffer: exact length in bytes, capacity folded
/// into the allocation so `runlet_str_free` can rebuild the box.
#[repr(C)]
pub struct RunletBuffer {
    pub data: *mut c_char,
    pub len: usize,
}

/// The two slots `runlet_format_lua` fills. The shim zeroes both first, so
/// the caller can read them on every status.
#[repr(C)]
pub struct RunletFormatResult {
    pub out: RunletBuffer,
    pub err: RunletBuffer,
}

/// Boxed-slice transfer: length is exact, capacity is folded into the box
/// so the free side can rebuild it with a plain `Box::from_raw`.
fn leak_buffer(bytes: &[u8]) -> RunletBuffer {
    let boxed: Box<[u8]> = bytes.to_vec().into_boxed_slice();
    let len = boxed.len();
    RunletBuffer {
        data: Box::into_raw(boxed).cast::<c_char>(),
        len,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn runlet_format_lua(
    input: *const c_char,
    input_len: usize,
    result: *mut RunletFormatResult,
) -> i32 {
    if result.is_null() {
        return -1;
    }
    unsafe {
        (*result).out = RunletBuffer { data: std::ptr::null_mut(), len: 0 };
        (*result).err = RunletBuffer { data: std::ptr::null_mut(), len: 0 };
        if input.is_null() {
            return -1;
        }
        let bytes = slice::from_raw_parts(input.cast::<u8>(), input_len);
        let Ok(source) = std::str::from_utf8(bytes) else {
            return 2;
        };
        match format_text(source) {
            Ok(code) => {
                (*result).out = leak_buffer(code.as_bytes());
                0
            }
            Err(message) => {
                (*result).err = leak_buffer(message.as_bytes());
                1
            }
        }
    }
}

/// Releases a buffer handed out by `runlet_format_lua`. Same pointer and
/// length the shim returned; both are required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn runlet_str_free(ptr: *mut c_char, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let boxed = Box::from_raw(slice::from_raw_parts_mut(ptr.cast::<u8>(), len));
        drop(boxed);
    }
}
