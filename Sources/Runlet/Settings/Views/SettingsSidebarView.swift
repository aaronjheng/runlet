import SwiftUI

// MARK: - Settings Sidebar View

/// Stock `.sidebar` styling throughout: headers and selection are
/// system-supplied.
struct SettingsSidebarView: View {
    @Environment(SettingsNavigationState.self) private var navigation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List(selection: selection) {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                Label(pane.title, systemImage: pane.icon)
                    .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)
        .background(colorScheme == .dark ? AnyShapeStyle(AppColor.secondaryBackground) : AnyShapeStyle(Color.clear))
    }

    /// `List` hands back an optional selection; routing it through `select`
    /// records history.
    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { navigation.pane },
            set: { if let pane = $0 { navigation.select(pane) } }
        )
    }
}
