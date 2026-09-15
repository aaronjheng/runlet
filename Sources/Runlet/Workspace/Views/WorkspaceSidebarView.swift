import SwiftUI

// MARK: - Workspace Sidebar

struct WorkspaceSidebarView: View {
    @Environment(TabState.self) private var tab

    var body: some View {
        @Bindable var tab = tab

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let selectedConnection = tab.selectedConnection {
                    VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xSmall) {
                            Text(selectedConnection.name)
                                .font(.headline)
                                .fontWeight(.bold)
                                .lineLimit(1)
                            Spacer(minLength: AppSpacing.small)
                            if selectedConnection.environment != .unspecified {
                                Badge(
                                    text: selectedConnection.environment.rawValue,
                                    systemImage: selectedConnection.environment.icon,
                                    foregroundColor: selectedConnection.environment.badgeForegroundColor,
                                    backgroundColor: selectedConnection.environment.badgeBackgroundColor
                                )
                                .help("Environment: \(selectedConnection.environment.rawValue)")
                            }
                            Badge(
                                text: selectedConnection.mode.title,
                                foregroundColor: selectedConnection.mode.badgeForegroundColor,
                                backgroundColor: selectedConnection.mode.badgeBackgroundColor
                            )
                            .help("Connection mode: \(selectedConnection.mode.title)")
                        }

                        Text(selectedConnection.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.small)
                }
            }

            Divider()

            List(selection: $tab.currentSection) {
                ForEach(WorkspaceSection.allCases, id: \.self) { view in
                    WorkspaceNavRow(
                        title: view.rawValue,
                        systemImage: view.icon,
                        isSelected: tab.currentSection == view
                    )
                    .tag(view)
                }
            }
            .listStyle(.sidebar)
            .flatSidebarBackground()

            Divider()

            PanelFooterBar {
                Button("Disconnect", systemImage: "power") {
                    tab.disconnect()
                }
                .buttonStyle(IconButtonStyle())
                .help("Disconnect")
                Spacer()
            }
        }
    }
}

/// Sidebar nav row with the same hover wash as connection rows and data rows.
/// System List selection still paints the selected state; this only adds the
/// missing hover so the sidebar matches `fullWidthListRow` behavior.
private struct WorkspaceNavRow: View {
    let title: String
    let systemImage: String
    var isSelected: Bool = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .sidebarHoverWash(active: isHovering && !isSelected)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
        .help(title)
        .accessibilityLabel(title)
    }
}
