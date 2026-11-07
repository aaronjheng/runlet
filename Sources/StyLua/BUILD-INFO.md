# StyLua vendored Lua formatter

The Functions tab's native formatter: JohnnyMorganz's StyLua backend as a
statically linked Rust archive behind a C-ABI shim. Nothing here runs a
Lua runtime; the formatter is native Rust.

- Built by `build.sh` (`sh Sources/StyLua/build.sh`): compiles the in-repo
  shim crate (`shim/`, a standalone Cargo project) for arm64 - Runlet
  targets macOS 27+, which shipped no Intel release - and writes
  `Sources/StyLua/lib/librunlet_stylua.xcframework`, which is
  git-ignored - `just build` refuses to run without it.
- Dependency: `shim/Cargo.toml` pins `stylua_lib` to one upstream revision
  by `rev` (cargo fetches it like any git dependency, first build only,
  cached in `~/.cargo`) and `shim/Cargo.lock` pins the resolved set.
  `default-features = false` drops editorconfig, the LSP crates, and the
  wasm bindings - none belong in a static archive.
- App-facing surface: `LuaFormatter.swift` binds the shim's two exports
  directly with `@_silgen_name` - no C target, no header file. Results
  cross as a C-repr `RunletFormatResult` (out/err buffers; lengths
  `usize` ↔ Swift `Int`), raw UTF-8, freed via `runlet_str_free(ptr, len)`
  with the exact pointer/length pair.

## Pinned upstream

- Repository: https://github.com/JohnnyMorganz/StyLua
- Revision: `56f9630407f6bf6ee524fb1d7fe71f005a570478` (tag `v2.6.0`;
  bump = update the `rev` entry in `shim/Cargo.toml`, relock, re-verify
  formatting)
- Options: Lua 5.1 grammar (Redis function libraries run 5.1), 2-space
  indent (Plume's editor indent unit), column width 100 (Canoe's Oxfmt
  line width), `AutoPreferSingle` quotes (the function template and most
  Redis Lua samples use single quotes), call parentheses always, output
  verified by reparse (`OutputVerification::Full`)
- Toolchain: `shim/rust-toolchain.toml` pins stable (same archive profile
  as Canoe's Oxfmt shim)
- Upstream license: MPL-2.0 (`LICENSE-stylua.md`)
