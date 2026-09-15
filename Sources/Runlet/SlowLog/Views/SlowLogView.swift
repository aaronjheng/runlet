import SwiftUI

// MARK: - Slow Log View

struct SlowLogView: View {
    @Environment(TabState.self) private var tab
    @State private var filterText = ""
    @State private var selection = Set<Int>()

    private var filteredEntries: [SlowLogEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return tab.slowLogEntries }
        return tab.slowLogEntries.filter { entry in
            entry.commandText.lowercased().contains(query)
                || entry.clientIP.lowercased().contains(query)
                || entry.clientName.lowercased().contains(query)
        }
    }

    var body: some View {
        @Bindable var tab = tab

        VStack(spacing: 0) {
            // Header
            HStack(spacing: AppSpacing.small) {
                FilterField("Filter command, client, or name", text: $filterText)
                    .frame(maxWidth: .infinity)

                RefreshControl(
                    autoRefreshInterval: $tab.slowLogConfig.autoRefreshInterval,
                    isLoading: tab.isLoadingSlowLog,
                    intervals: SlowLogConfig.autoRefreshOptions.map(\.value)
                ) {
                    Task { await tab.fetchSlowLog() }
                }
            }
            .panelToolbar(horizontalPadding: AppSpacing.small)

            Divider()

            if let error = tab.slowLogError {
                ErrorBanner(message: error, dismissAction: { tab.slowLogError = nil })
                Divider()
            }

            // Entries list
            if filteredEntries.isEmpty {
                Spacer()
                if tab.isLoadingSlowLog {
                    LoadingState(message: "Loading slow log…")
                } else if filterText.isEmpty {
                    ContentUnavailableView(
                        "No slow log entries",
                        systemImage: "hourglass",
                        description: Text(
                            "Queries slower than \(slowLogThresholdText) will appear here")
                    )
                    Button("Refresh") {
                        Task { await tab.fetchSlowLog() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, AppSpacing.small)
                } else {
                    ContentUnavailableView(
                        "No matching entries",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different filter.")
                    )
                    Button("Clear Filter") {
                        filterText = ""
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, AppSpacing.small)
                }
                Spacer()
            } else {
                Table(filteredEntries, selection: $selection) {
                    TableColumn("ID") { entry in
                        Text("#\(entry.id)")
                            .font(AppFont.monoSubheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(60)

                    TableColumn("Duration") { entry in
                        Text(entry.durationText)
                            .font(AppFont.monoSubheadline)
                            .foregroundStyle(durationColor(entry.duration))
                            .help("Red at 1s or more, orange at 10ms or more")
                    }
                    .width(90)

                    TableColumn("Time") { entry in
                        Text(entry.timestampText)
                            .font(AppFont.monoSubheadline)
                            .foregroundStyle(.secondary)
                            .help(entry.relativeTimestampText)
                    }
                    .width(190)

                    TableColumn("Command") { entry in
                        Text(entry.commandText)
                            .font(AppFont.monoSubheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(entry.commandText)
                    }

                    TableColumn("Client") { entry in
                        Text(entry.clientIP)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .width(130)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: Int.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        if let entry = filteredEntries.first(where: { $0.id == id }) {
                            Button("Copy Command") {
                                copyToPasteboard(entry.commandText)
                            }
                            Button("Copy Client") {
                                copyToPasteboard(entry.clientIP)
                            }
                            Button("Copy Row") {
                                copyToPasteboard("#\(entry.id)\t\(entry.commandText)\t\(entry.clientIP)")
                            }
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if tab.isLoadingSlowLog, !filteredEntries.isEmpty {
                        HStack(spacing: AppSpacing.xSmall) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, AppSpacing.small)
                        .padding(.vertical, AppSpacing.xSmall)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        )
                        .padding(.top, AppSpacing.small)
                    }
                }
            }

            Divider()

            // Footer
            PanelFooterBar {
                StatusFooterView(
                    countText: footerCountText
                )
                Spacer()
            }
        }
        .task(id: tab.slowLogConfig.autoRefreshInterval) {
            // Fetch once, then keep the refresh loop alive while an interval
            // is set. Changing the interval restarts this task.
            await tab.fetchSlowLog()
            let interval = tab.slowLogConfig.autoRefreshInterval
            guard interval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, !tab.isLoadingSlowLog else { continue }
                await tab.fetchSlowLog()
            }
        }
    }

    private var slowLogThresholdText: String {
        let micros = tab.slowLogConfig.threshold
        if micros >= 1_000_000 {
            return String(format: "%.1f s", Double(micros) / 1_000_000)
        } else if micros >= 1_000 {
            return String(format: "%.0f ms", Double(micros) / 1_000)
        }
        return "\(micros) µs"
    }

    private var footerCountText: String {
        let total = tab.slowLogEntries.count
        let filtered = filteredEntries.count
        if filterText.isEmpty || filtered == total {
            return pluralizedCount(total, singular: "entry")
        }
        return "Showing \(filtered) of " + pluralizedCount(total, singular: "entry")
    }

    private func durationColor(_ duration: Int) -> Color {
        if duration >= 1_000_000 {
            return AppColor.error
        } else if duration >= 10_000 {
            return AppColor.warning
        }
        return .primary
    }

}
