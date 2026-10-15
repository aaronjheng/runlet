# Runlet

Native macOS Redis GUI client built with Swift and SwiftUI.

## Features

- **Standalone & Cluster** — full support for both deployment modes with automatic topology discovery, hash-slot routing, and MOVED/ASK redirect handling
- **SSH Tunneling** — connect to Redis instances behind firewalls via SSH: built-in mode (password or key-based auth, Ed25519/ECDSA) or system-SSH mode that drives local `ssh(1)`, reusing `~/.ssh/config`, agents, ProxyJump and certificates with multiplexed connection sharing
- **TLS / mTLS** — secure connections with optional CA, client cert, and client key
- **Keys** — scan, filter, and manage keys with flat list or namespace tree views; as-you-type filtering, scroll-triggered paging, keyboard navigation (↑↓, ⌘R, ⌘F), per-row TTL badges, and inline TTL editing
- **Type-Aware Value Editor** — dedicated viewers for strings (with JSON/MessagePack/hex/base64/gzip formatting, plus file import/export), hashes, lists, sets, and sorted sets; full-value viewer for collection members, multi-select bulk member deletion, and inline editing
- **Interactive Shell** — Redis CLI with syntax highlighting, command auto-complete with syntax hints, dangerous-command detection, and history navigation
- **Redis Functions** — manage Lua function libraries (7.0+): browse, load, edit, and delete libraries with a tree-sitter-powered Lua editor (syntax highlighting, `redis.*` API completion, DRYRUN validation); test functions via an FCALL/FCALL_RO call bench; monitor running scripts and engine stats with FUNCTION STATS
- **Command Profiler** — live MONITOR-based command capture with filtering, noise suppression, FCALL-to-library name mapping, CSV export, and "Open in Shell"
- **Slow Log** — query slow log entries with auto-refresh, duration color-coding, and "Open in Shell"
- **Database Analysis** — statistical overview of key counts, memory usage, type distribution with bars, top keys and namespaces breakdown, with one-click drill-down into the Keys browser
- **Server Info** — structured INFO output with in-panel search, per-section copy, and cluster topology visualization
- **Connection Management** — import/export connections, environment tagging (development/production), credentials stored with connection config, and one-click reconnect from the workspace sidebar
- **Multi-Tab** — tabbed window interface with keyboard shortcuts (⌘T, ⌘W, ⌘1–9, ⇧⌘1–7 section switching, ⌘R section refresh)
- **RESP2 & RESP3** — automatic protocol negotiation with RESP3 fallback

## Requirements

- macOS 27+
- Xcode 27+ (Swift 6.4)
- [Just](https://github.com/casey/just)

## Build & Run

```bash
# Build and open the app
just run

# Build release only
just build

# Install to ~/Applications
just install
```

## Development

```bash
# Lint
just lint
just lint-fix

# Format
just format
just format-check

# Clean build artifacts
just clean
```

## License

Runlet is licensed under the [BSD-3-Clause License](https://opensource.org/licenses/BSD-3-Clause). See [LICENSE](LICENSE) for more details.
