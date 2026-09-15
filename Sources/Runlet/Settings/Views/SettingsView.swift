import SwiftUI

// MARK: - Settings View

/// App-level configuration panel, hosted in a standalone window from the app
/// menu (`Settings…`, ⌘,). Every pane is a stock `Form`, so cards, headers
/// and hairlines are system-drawn. Every control applies instantly through
/// `SettingsStore`.
struct SettingsView: View {
    @Environment(SettingsNavigationState.self) private var navigation
    @Bindable private var store = SettingsStore.shared

    /// Live binding so a theme change from the menu is reflected while the
    /// panel is open (and vice versa through `validateMenuItem`).
    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: store.settings.appearance) ?? .system },
            set: { appearance in
                store.settings.appearance = appearance.rawValue
                store.save()
                appearance.apply()
                for window in NSApp.windows {
                    appearance.applyToWindow(window)
                }
            }
        )
    }

    var body: some View {
        switch navigation.pane {
        case .application: applicationPane
        case .appearance: appearancePane
        }
    }

    // MARK: - Application

    private var applicationPane: some View {
        Form {
            Section {
                Toggle(
                    "Confirm before quitting",
                    isOn: Binding(
                        get: { store.settings.confirmBeforeQuit },
                        set: {
                            store.settings.confirmBeforeQuit = $0
                            store.save()
                        }
                    )
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance

    private var appearancePane: some View {
        Form {
            Section {
                HStack {
                    Text("Style")
                        .lineLimit(1)
                    Spacer(minLength: AppSpacing.small)
                    Picker("", selection: appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.name).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Theme")
            }
        }
        .formStyle(.grouped)
    }
}
