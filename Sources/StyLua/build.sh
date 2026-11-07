#!/bin/sh
# Builds the vendored Lua formatter (this package) from source: the
# in-repo shim crate - a standalone Cargo project whose StyLua dependency
# is git-pinned and resolved by cargo itself (first build downloads into
# the cargo home) - is compiled and packaged as the git-ignored xcframework
# the SPM package links against. arm64 only: Runlet targets macOS 27+,
# which shipped no Intel release.
#
# Usage: sh Sources/StyLua/build.sh   (the Justfile recipe `just build`
# runs it automatically when the framework is missing)
set -eu

cd "$(dirname "$0")"
out="$PWD/lib/librunlet_stylua.xcframework"

command -v cargo >/dev/null 2>&1 || { echo "cargo not found - install rustup (rustup.rs)" >&2; exit 1; }

cd shim
# rust-toolchain.toml in this folder pins the toolchain; the release
# profile enables `strip = "symbols"`, so the archive needs no
# post-processing.
cargo build --release

mkdir -p ../lib
rm -rf "$out"
xcodebuild -create-xcframework \
    -library target/release/librunlet_stylua_shim.a \
    -output "$out" >/dev/null

echo "Built $out"
