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
    /// Namespace separator for key tree grouping. Only the first character
    /// is meaningful (`KeyNamespaceTree.normalizedSeparator`).
    var namespaceSeparator: String = ":"
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case appearance, confirmBeforeQuit, namespaceSeparator
    }

    /// Field-by-field decoding: a settings.json written before a newer field
    /// existed must not fail the whole decode (which would reset every other
    /// preference to defaults).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        appearance = try container.decodeIfPresent(Int.self, forKey: .appearance) ?? 0
        confirmBeforeQuit = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeQuit) ?? true
        namespaceSeparator = try container.decodeIfPresent(String.self, forKey: .namespaceSeparator) ?? ":"
    }
}
