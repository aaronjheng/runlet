import SwiftUI

struct ProfilerView: View {
    @Environment(TabState.self) private var tab
    @State private var filterText = ""
    @State private var autoScroll = true
    @State private var hideNoiseCommands = true
    @State private var selectedEntryID: RedisProfilerEntry.ID?
    @State private var libraryColumnEnabled = false
    @State private var showingProductionWarning = false

    private var isProduction: Bool {
        tab.selectedConnection?.environment == .production
    }

    private var hasFunctionLibraries: Bool {
        !tab.functionLibraries.isEmpty
    }

    /// Effective column visibility: the user opt-in must be on *and* libraries
    /// must be loaded (so the column auto-hides after a FLUSH, for example).
    private var showLibraryColumn: Bool {
        libraryColumnEnabled && hasFunctionLibraries
    }

    private var filteredEntries: [RedisProfilerEntry] {
        let visibleEntries =
            hideNoiseCommands
            ? tab.profilerEntries.filter { !$0.isNoiseCommand }
            : tab.profilerEntries

        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visibleEntries }

        return visibleEntries.filter { entry in
            entry.searchText.contains(query)
        }
    }

    private var selectedEntry: RedisProfilerEntry? {
        guard let selectedEntryID else { return nil }
        return filteredEntries.first { $0.id == selectedEntryID }
    }

    private var lastVisibleEntryID: RedisProfilerEntry.ID? {
        filteredEntries.last?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfilerToolbarView(
                filterText: $filterText,
                autoScroll: $autoScroll,
                hideNoiseCommands: $hideNoiseCommands,
                libraryColumnEnabled: $libraryColumnEnabled,
                canShowLibraryColumn: hasFunctionLibraries,
                isStarting: tab.isProfilerStarting,
                isRunning: tab.isProfilerRunning,
                hasEntries: !tab.profilerEntries.isEmpty,
                onToggleCapture: toggleCapture,
                onClear: clearProfiler
            )

            if let error = tab.profilerError {
                ErrorBanner(message: error, severity: .warning, dismissAction: { tab.profilerError = nil })
            }

            ProfilerContentView(
                entries: filteredEntries,
                isStarting: tab.isProfilerStarting,
                isRunning: tab.isProfilerRunning,
                isCluster: tab.selectedConnection?.mode == .cluster || !tab.clusterNodes.isEmpty,
                selectedEntryID: $selectedEntryID,
                autoScroll: $autoScroll,
                lastVisibleEntryID: lastVisibleEntryID,
                showLibraryColumn: showLibraryColumn,
                libraries: tab.functionLibraries,
                onStart: startProfilerGated
            )

            Divider()

            ProfilerFooterView(
                filteredCount: filteredEntries.count,
                retainedCount: tab.profilerEntries.count,
                capturedCount: tab.profilerCapturedCount,
                selectedEntry: selectedEntry,
                isStarting: tab.isProfilerStarting,
                isRunning: tab.isProfilerRunning
            )
        }
        .task {
            // Keep function libraries loaded so FCALL entries can be resolved to
            // their owning library without first visiting the Functions tab.
            guard tab.activeSession?.isConnected == true else { return }
            if tab.serverInfo.isEmpty { await tab.loadServerInfo() }
            if tab.supportsFunctions && tab.functionLibraries.isEmpty {
                await tab.fetchFunctionLibraries()
            }
        }
        .alert("Start Profiler on Production?", isPresented: $showingProductionWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Start Profiler") {
                tab.startProfiler()
            }
        } message: {
            Text(
                "MONITOR streams every command executed on the server. "
                    + "This can slow busy servers and may capture sensitive data "
                    + "such as passwords.")
        }
    }

    private func toggleCapture() {
        if tab.isProfilerRunning || tab.isProfilerStarting {
            tab.stopProfiler()
        } else {
            startProfilerGated()
        }
    }

    private func startProfilerGated() {
        if isProduction {
            showingProductionWarning = true
        } else {
            tab.startProfiler()
        }
    }

    private func clearProfiler() {
        selectedEntryID = nil
        tab.clearProfiler()
    }
}

private struct ProfilerContentView: View {
    let entries: [RedisProfilerEntry]
    let isStarting: Bool
    let isRunning: Bool
    let isCluster: Bool
    @Binding var selectedEntryID: RedisProfilerEntry.ID?
    @Binding var autoScroll: Bool
    let lastVisibleEntryID: RedisProfilerEntry.ID?
    let showLibraryColumn: Bool
    let libraries: [RedisFunctionLibrary]
    let onStart: () -> Void

    var body: some View {
        if entries.isEmpty {
            ProfilerEmptyStateView(
                isStarting: isStarting,
                isRunning: isRunning,
                isCluster: isCluster,
                onStart: onStart
            )
        } else {
            ProfilerEntriesView(
                entries: entries,
                selectedEntryID: $selectedEntryID,
                autoScroll: $autoScroll,
                lastVisibleEntryID: lastVisibleEntryID,
                showLibraryColumn: showLibraryColumn,
                libraries: libraries
            )
        }
    }
}

private struct ProfilerEmptyStateView: View {
    let isStarting: Bool
    let isRunning: Bool
    let isCluster: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if isStarting {
                ContentUnavailableView(
                    "Starting profiler",
                    systemImage: "circle.dotted",
                    description: Text("Connecting to MONITOR…")
                )
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, AppSpacing.small)
            } else if isRunning {
                ContentUnavailableView(
                    "Waiting for Redis commands",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(
                        isCluster
                            ? "Run commands from Shell or another client to see them here. MONITOR shows a single node."
                            : "Run commands from Shell or another client to see them here.")
                )
            } else {
                ContentUnavailableView(
                    "Profiler stopped",
                    systemImage: "waveform.path.ecg"
                )
                Button("Start Profiler", action: onStart)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, AppSpacing.small)
            }
            if !isRunning && !isStarting {
                Spacer().frame(height: AppSpacing.large)
                Label("MONITOR can slow busy servers", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct ProfilerToolbarView: View {
    @Binding var filterText: String
    @Binding var autoScroll: Bool
    @Binding var hideNoiseCommands: Bool
    @Binding var libraryColumnEnabled: Bool
    let canShowLibraryColumn: Bool
    let isStarting: Bool
    let isRunning: Bool
    let hasEntries: Bool
    let onToggleCapture: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                FilterField("Filter command, node, source, database, or raw text", text: $filterText)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .help("Keep the newest commands visible")

                Toggle("Hide noise", isOn: $hideNoiseCommands)
                    .toggleStyle(.switch)
                    .help("Hide PING and other polling commands")

                Toggle("Library", isOn: $libraryColumnEnabled)
                    .toggleStyle(.switch)
                    .disabled(!canShowLibraryColumn)
                    .help("Show the owning library for FCALL commands")

                Button(action: onToggleCapture) {
                    Label(captureButtonTitle, systemImage: captureButtonIcon)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isStarting)

                Button(action: onClear) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!hasEntries)
            }
            .panelToolbar(horizontalPadding: AppSpacing.small)

            Divider()
        }
    }

    private var captureButtonTitle: String {
        if isStarting { return "Starting" }
        return isRunning ? "Stop" : "Start"
    }

    private var captureButtonIcon: String {
        if isStarting { return "circle.dotted" }
        return isRunning ? "stop.fill" : "play.fill"
    }
}

private struct ProfilerStatusIndicator: View {
    let isStarting: Bool
    let isRunning: Bool

    var body: some View {
        Label(statusText, systemImage: statusIcon)
            .foregroundStyle(isRunning || isStarting ? AppColor.success : .secondary)
    }

    private var statusText: String {
        if isStarting { return "Starting" }
        return isRunning ? "Running" : "Stopped"
    }

    private var statusIcon: String {
        if isStarting { return "circle.dotted" }
        return isRunning ? "circle.fill" : "circle"
    }
}

private struct ProfilerEntriesView: View {
    let entries: [RedisProfilerEntry]
    @Binding var selectedEntryID: RedisProfilerEntry.ID?
    @Binding var autoScroll: Bool
    let lastVisibleEntryID: RedisProfilerEntry.ID?
    let showLibraryColumn: Bool
    let libraries: [RedisFunctionLibrary]

    var body: some View {
        VStack(spacing: 0) {
            ProfilerHeaderRow(showLibraryColumn: showLibraryColumn)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            ProfilerEntryRow(
                                entry: entry,
                                libraries: libraries,
                                showLibraryColumn: showLibraryColumn,
                                isSelected: selectedEntryID == entry.id,
                                onSelect: { selectedEntryID = entry.id }
                            )
                            .id(entry.id)
                        }
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                        return distanceFromBottom
                    } action: { _, distanceFromBottom in
                        // Auto-disable auto-scroll when the user scrolls away from the bottom.
                        if autoScroll && distanceFromBottom > 60 {
                            autoScroll = false
                        }
                    }
                }
                .onChange(of: lastVisibleEntryID) { _, newValue in
                    guard autoScroll, let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct ProfilerHeaderRow: View {
    let showLibraryColumn: Bool

    var body: some View {
        HStack(spacing: AppSpacing.compact) {
            Text("Time")
                .frame(width: 100, alignment: .leading)
            Text("DB")
                .frame(width: 44, alignment: .leading)
            Text("Node")
                .frame(width: 170, alignment: .leading)
            Text("Source")
                .frame(width: 170, alignment: .leading)
            Text("Command")
                .frame(width: 110, alignment: .leading)
            if showLibraryColumn {
                Text("Library")
                    .frame(width: 150, alignment: .leading)
            }
            Text("Arguments")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.mini)
        .background(AppColor.controlBackground)
    }
}

private struct ProfilerEntryRow: View {
    let entry: RedisProfilerEntry
    let libraries: [RedisFunctionLibrary]
    let showLibraryColumn: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var libraryText: String? {
        entry.fcallLibraryName(in: libraries)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppSpacing.compact) {
                Text(entry.timeText)
                    .frame(width: 100, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(entry.databaseText)
                    .frame(width: 44, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(entry.nodeText)
                    .frame(width: 170, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                Text(entry.source)
                    .frame(width: 170, alignment: .leading)
                    .truncationMode(.middle)
                Text(entry.commandName)
                    .frame(width: 110, alignment: .leading)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                if showLibraryColumn {
                    Text(libraryText ?? "-")
                        .frame(width: 150, alignment: .leading)
                        .truncationMode(.middle)
                        .foregroundStyle(libraryText == nil ? .secondary : .primary)
                }
                Text(entry.argumentsText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .truncationMode(.middle)
            }
            .font(AppFont.monoSubheadline)
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.large)
            .padding(.vertical, AppSpacing.mini)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? (controlActiveState == .inactive
                        ? Color.primary.opacity(0.08) : AppColor.selectionBackground)
                    : isHovering ? AppColor.hoverBackground : Color.clear
            )
            .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profiler entry: \(entry.commandText)")
        .help("Select to preview raw line")
        .contextMenu {
            Button("Copy Raw Line") {
                copyToPasteboard(entry.rawLine)
            }
            Button("Copy Command") {
                copyToPasteboard(entry.commandText)
            }
        }
    }
}

private struct ProfilerFooterView: View {
    let filteredCount: Int
    let retainedCount: Int
    let capturedCount: Int
    let selectedEntry: RedisProfilerEntry?
    let isStarting: Bool
    let isRunning: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let selectedEntry {
                HStack(alignment: .top, spacing: AppSpacing.small) {
                    Text("Raw")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)
                    Text(selectedEntry.rawLine)
                        .font(AppFont.monoSubheadline)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, AppSpacing.large)
                .padding(.vertical, AppSpacing.small)

                Divider()
            }

            PanelFooterBar {
                ProfilerStatusIndicator(isStarting: isStarting, isRunning: isRunning)
                StatusFooterView(
                    countText: "Showing \(filteredCount) of \(retainedCount) commands",
                    sizeText: "Captured \(capturedCount)"
                )
                Spacer()
            }
        }
    }
}
