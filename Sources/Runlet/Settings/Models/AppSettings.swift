import Foundation

// MARK: - App Settings

/// The app-level configuration schema, persisted as a whole in `settings.json`.
/// UI state (split positions, panel sizes) is deliberately not here — that
/// stays in `UserDefaults`, owned by AppKit.
struct AppSettings: Codable, Equatable {
    /// `AppAppearance` raw value. The enum mapping lives with the callers so
    /// `Theme` never depends on this area.
    var appearance: Int = 0
    /// When true, quitting the app shows a confirmation dialog. Defaults to
    /// true so a stray ⌘Q never drops open connections unnoticed.
    var confirmBeforeQuit: Bool = true
}
