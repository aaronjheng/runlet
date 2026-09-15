# Runlet

macOS native Redis client with SSH tunnel support, written in Swift/SwiftUI.

## Directory Layout

`Sources/Runlet/` is flat: four process-level files at the root plus one folder per concrete area, mirrored 1:1 by Xcode groups in the project.

Root files: `RunletApp` (process entry), `AppDelegate` + `AppMenu` (windows, tabs, menu bar), `AppLogger` (unified logging, used everywhere).

Area folders:

- Feature areas, each holding whichever of `Models/` / `State/` (`TabState` extensions and use cases) / `Views/` it needs, plus `Services/` only for area-private persistence (e.g. keys preferences): `Analysis`, `Connection`, `Functions`, `KeyDetail`, `Keys`, `Profiler`, `ServerInfo`, `Shell`, `SlowLog`, `Workspace`
- Backends: `Redis/` (client, cluster client, RESP parser, MONITOR client), `SSH/` (tunnel facade, `BuiltIn/` NIO implementation, `System/` `ssh(1)` multiplexing, `Cluster/`)
- Shared toolkit: `Components/` (reusable views + the pasteboard helper their copy buttons use), `Concurrency/` (`withTimeout`), `Editor/` (syntax-highlighting code editor), `Theme/` (color/font/metrics tokens + light/dark switching)
- `Session/` (`TabState` core, `ConnectionStore`, `AppDatabase` SQLite persistence, `TabManager`)

Naming rule (for the main program under `Sources/Runlet/` only, not top-level engineering dirs like `Tools/`, `Vendor/`): no bucket names (`Tools`, `Utilities`, `Core`, `DesignSystem`, `Inspector`, …). If a folder needs "and misc" to describe it, split it instead.

## Dependency Rule

Outer layers may use inner layers, never the reverse:

- `Views/` (SwiftUI) may use anything below it.
- Area `State/`, `Session/`, and persistence may use `Models/`, `Redis/`, `SSH/`, `Concurrency/`.
- `Models/`, `Redis/`, `SSH/`, `Concurrency/` must never `import SwiftUI`. Presentation mapping for a domain type lives in a `Type+Presentation.swift` next to the views that need it.
- `Redis/` and `SSH/` never reference views, `TabState`, or areas; areas never reference each other's `State/`.

## Code Conventions

- Use the `@Observable` macro (macOS 14+); no `@Published` / ObservableObject, and no Combine dependency.
- UI types are annotated `@MainActor`; networking types are marked `@Sendable`.
- Concurrency primitives: `Mutex`, `actor`, `CheckedContinuation`; `DispatchQueue` is reserved for `RedisClient` I/O only.
- Errors use the unified `RedisError` enum conforming to `LocalizedError`.
- Dangerous operations on production environments require confirmation via `ProductionConfirmView` by typing a keyword.
- Construct tunnels and Redis sessions only through the shared factories `SSHTunnel.connect` and `makeRedisSession`; target cluster capabilities through `RedisSession` (`mode`, `clusterNodes()`, `send(_:to:)`), never `as? RedisClusterClient` downcasts.
- App-level configuration lives in `settings.json` in Application Support, owned solely by `SettingsStore`. It is local file storage with no sync today; if sync is ever needed it must be designed explicitly per item. `UserDefaults` holds only AppKit-managed UI state (split positions, panel geometry), enforced by the `no_direct_userdefaults` SwiftLint rule. `State/` extensions read settings through `SettingsStore.shared`.
- Swift `private` is file-scoped: when a type is split across files, members shared by those files must drop `private` (stay module-internal); keep `private` for within-file helpers.

## Git Workflow

Commit messages are a single sentence, capitalized, with no Conventional Commit prefix, e.g. `Add delete menu to connection list`.

## Build & Run

Follow the `.swift-format` and `.swiftlint.yml` configurations.

```bash
just lint          # swiftlint
just lint-fix      # swiftlint --fix
just format        # swift-format
just format-check  # swift-format lint
just build         # xcodebuild release
just run           # build + open app
just install       # build + copy to ~/Applications
just clean         # rm -rf .build
```
