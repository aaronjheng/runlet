// swift-tools-version:6.1
import PackageDescription

// Runlet's native Lua formatter: JohnnyMorganz's StyLua backend, compiled
// by the Rust toolchain into the static archive shipped by the StyLua
// binary target (see BUILD-INFO.md for the pin and the build recipe).
// Swift binds the shim's C ABI via @_silgen_name in LuaFormatter.swift -
// no C target, no Lua runtime involved.
let package = Package(
    name: "StyLua",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StyLua", targets: ["StyLuaBin"]),
    ],
    targets: [
        .binaryTarget(name: "StyLuaBin", path: "lib/librunlet_stylua.xcframework"),
    ]
)
