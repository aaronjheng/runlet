import AppKit
import SwiftUI

struct ShellView: View {
    @Environment(TabState.self) private var tab
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var input = ""
    @State private var historyIndex = -1
    @State private var historyDraft = ""
    @State private var showCompletions = false
    @State private var completionIndex: Int?
    /// Pointer position recorded when the suggestion panel opens, so the
    /// hover event fired by the panel appearing under a stationary cursor can
    /// be told apart from real pointer movement.
    @State private var hoverAnchorLocation: CGPoint?
    @State private var showDangerousCommandAlert = false
    @State private var showProductionConfirm = false
    @State private var productionConfirmText = ""
    @State private var pendingCommand = ""
    @State private var autoScroll = true
    @FocusState private var inputFocused: Bool

    /// Commands that require confirmation only in production environments.
    private let productionConfirmCommands: Set<String> = [
        "FLUSHDB", "FLUSHALL", "FLUSHDB ASYNC", "FLUSHALL ASYNC", "SHUTDOWN", "DEBUG", "SLAVEOF", "REPLICAOF", "CONFIG RESETSTAT", "SWAPDB",
        "MOVE",
    ]

    /// Commands that require confirmation in ALL environments, including non-production.
    /// Key deletes always confirm, matching the Keys delete flow.
    private let alwaysConfirmCommands: Set<String> = [
        "FLUSHDB", "FLUSHALL", "FLUSHDB ASYNC", "FLUSHALL ASYNC", "SHUTDOWN", "SWAPDB",
        "DEL", "UNLINK",
    ]

    var filteredCompletions: [String] {
        guard !input.isEmpty else { return [] }
        // A trailing space means the command word is finished: first-word
        // suggestions no longer apply (the catalog has no second-word data).
        guard !input.hasSuffix(" ") else { return [] }
        let parts = input.split(separator: " ")
        if parts.count <= 1 {
            return RedisCommandCatalog.completions(for: String(parts.first ?? ""))
        }
        return []
    }

    private var completionsVisible: Bool {
        showCompletions && !filteredCompletions.isEmpty
    }

    /// Height of one suggestion row and how many rows the panel shows before
    /// it scrolls.
    private static let completionRowHeight: CGFloat = 26
    private static let maxVisibleCompletions = 6

    private var completionsBarHeight: CGFloat {
        CGFloat(min(filteredCompletions.count, Self.maxVisibleCompletions)) * Self.completionRowHeight
    }

    /// Floating command suggestions rendered as an overlay above the input
    /// strip: same width, top corners rounded, bottom edge flush with the
    /// strip so the two read as one surface. Living outside the layout keeps
    /// the history area and footer at a constant size while suggestions appear
    /// and disappear.
    private var completionsBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(filteredCompletions, id: \.self) { cmd in
                        completionRow(cmd)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: completionsBarHeight)
            .onChange(of: completionIndex) { _, index in
                guard let index else { return }
                proxy.scrollTo(filteredCompletions[index], anchor: .center)
            }
        }
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: AppRadius.large,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: AppRadius.large,
                style: .continuous
            )
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    /// One selectable suggestion row. `cmd` doubles as the scroll anchor id.
    /// Hovering moves the shared selection (menus style); the highlight is
    /// full-bleed and gets clipped by the panel's rounded silhouette.
    private func completionRow(_ cmd: String) -> some View {
        let index = filteredCompletions.firstIndex(of: cmd)
        return Button {
            acceptCompletion(at: index)
        } label: {
            Text(cmd)
                .font(AppFont.monoSubheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.small)
                .frame(minHeight: Self.completionRowHeight)
                .background(completionIndex == index ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering else { return }
            // Only a pointer that has actually moved since the panel opened
            // may steal the selection; a stationary cursor sitting where the
            // panel happens to expand must not.
            if let hoverAnchorLocation, NSEvent.mouseLocation != hoverAnchorLocation {
                completionIndex = index
            }
        }
        .help("Complete with \(cmd)")
    }

    /// Accepts the highlighted (or given) suggestion into the input.
    private func acceptCompletion(at index: Int? = nil) {
        let completions = filteredCompletions
        let resolved = index ?? completionIndex ?? 0
        guard completions.indices.contains(resolved) else { return }
        input = completions[resolved] + " "
        showCompletions = false
        completionIndex = nil
    }

    /// Moves the suggestion selection with wrap-around; arrow keys start at
    /// the first (↓) or last (↑) row when nothing is selected yet.
    private func moveCompletionSelection(_ delta: Int) {
        let count = filteredCompletions.count
        guard count > 0 else { return }
        let current = completionIndex ?? (delta > 0 ? -1 : 0)
        completionIndex = (current + delta + count) % count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.medium) {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .help("Keep the newest commands visible")
                    Spacer()
                    Button(
                        action: { tab.clearShellHistory() },
                        label: {
                            Label("Clear", systemImage: "trash")
                        }
                    )
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(tab.shellHistory.isEmpty)
                }
                .panelToolbar(horizontalPadding: AppSpacing.small)

                Divider()
            }

            // History list
            if tab.shellHistory.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "Enter Redis commands below",
                    systemImage: "terminal",
                    description: Text("Supports auto-complete, press Tab to complete")
                )
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(tab.shellHistory) { entry in
                                ShellHistoryRow(entry: entry)
                                    .id(entry.id)
                                    .contextMenu {
                                        Button("Copy Command") {
                                            copyToPasteboard(entry.command)
                                        }
                                        Button("Copy Result") {
                                            copyToPasteboard(entry.result)
                                        }
                                        Divider()
                                        Button("Delete", role: .destructive) {
                                            tab.deleteShellHistoryEntry(entry)
                                        }
                                    }
                            }
                        }
                        .onScrollGeometryChange(for: CGFloat.self) { geo in
                            geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                        } action: { _, distanceFromBottom in
                            // Auto-disable auto-scroll when the user scrolls away from the bottom.
                            if autoScroll && distanceFromBottom > 60 {
                                autoScroll = false
                            }
                        }
                    }
                    .onChange(of: tab.shellHistory.count) { _, _ in
                        guard autoScroll, let last = tab.shellHistory.last else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Input strip — flat terminal-style prompt pinned above the
            // footer. Suggestions float above it as an overlay, so showing
            // them never shifts the layout.
            Divider()

            VStack(spacing: AppSpacing.xSmall) {
                HStack(spacing: AppSpacing.small) {
                    Text("›")
                        .font(AppFont.dataCell)
                        .fontWeight(.bold)
                        .foregroundStyle(
                            inputFocused && controlActiveState != .inactive
                                ? Color.accentColor : AppColor.shellPrompt
                        )

                    TextField("Send a Redis command", text: $input, axis: .vertical)
                        .font(AppFont.monoBody)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .onSubmit { executeCommand() }
                        .onChange(of: input) { _, newValue in
                            showCompletions = !newValue.isEmpty
                            completionIndex = filteredCompletions.isEmpty ? nil : 0
                        }
                        .onKeyPress(.tab) {
                            if completionsVisible {
                                acceptCompletion()
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.escape) {
                            if showCompletions {
                                showCompletions = false
                                completionIndex = nil
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.upArrow) {
                            if completionsVisible {
                                moveCompletionSelection(-1)
                                return .handled
                            }
                            if !tab.shellHistory.isEmpty {
                                if historyIndex == -1 {
                                    historyDraft = input
                                }
                                historyIndex = min(historyIndex + 1, tab.shellHistory.count - 1)
                                input = tab.shellHistory[tab.shellHistory.count - 1 - historyIndex].command
                            }
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            if completionsVisible {
                                moveCompletionSelection(1)
                                return .handled
                            }
                            if historyIndex > 0 {
                                historyIndex -= 1
                                input = tab.shellHistory[tab.shellHistory.count - 1 - historyIndex].command
                            } else if historyIndex == 0 {
                                historyIndex = -1
                                input = historyDraft
                            }
                            return .handled
                        }

                    Button("Send command", systemImage: "arrow.up") {
                        executeCommand()
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(input.isEmpty)
                    .help(input.isEmpty ? "Type a command to send" : "Send command (Return)")
                }
                .padding(.horizontal, AppSpacing.large)
                .padding(.vertical, AppSpacing.small)
                .overlay(alignment: .top) {
                    if completionsVisible {
                        completionsBar
                            .offset(y: -completionsBarHeight)
                    }
                }
            }
            .background(.bar)
            .onChange(of: completionsVisible) { _, visible in
                hoverAnchorLocation = visible ? NSEvent.mouseLocation : nil
            }

            Divider()
            PanelFooterBar {
                StatusFooterView(countText: "\(tab.shellHistory.count) commands")
                Spacer()
            }
        }
        .onAppear { inputFocused = true }
        .alert("Dangerous Command", isPresented: $showDangerousCommandAlert) {
            Button("Cancel", role: .cancel) {
                pendingCommand = ""
            }
            Button("Execute", role: .destructive) {
                input = ""
                let cmd = pendingCommand
                pendingCommand = ""
                Task { await tab.executeCommand(cmd) }
            }
        } message: {
            if tab.selectedConnection?.environment == .production {
                Text("This is a PRODUCTION database. Are you sure you want to execute:\n\n\(pendingCommand)")
            } else {
                Text("This command is potentially destructive. Are you sure you want to execute:\n\n\(pendingCommand)")
            }
        }
        .sheet(isPresented: $showProductionConfirm) {
            ProductionConfirmView(
                title: "Execute on Production?",
                message: "This will execute the following command on a production"
                    + "server. This action cannot be undone.\n\n\(pendingCommand)",
                confirmText: "EXECUTE",
                confirmButtonTitle: "Execute",
                input: $productionConfirmText,
                onConfirm: {
                    input = ""
                    let cmd = pendingCommand
                    pendingCommand = ""
                    productionConfirmText = ""
                    showProductionConfirm = false
                    Task { await tab.executeCommand(cmd) }
                },
                onCancel: {
                    pendingCommand = ""
                    productionConfirmText = ""
                    showProductionConfirm = false
                }
            )
            .presentationSizing(.form)
        }
    }

    private func executeCommand() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        historyIndex = -1
        historyDraft = ""
        showCompletions = false
        completionIndex = nil

        let cmdUpper = cmd.uppercased().trimmingCharacters(in: .whitespaces)
        let isProduction = tab.selectedConnection?.environment == .production
        let isAlwaysConfirm = alwaysConfirmCommands.contains { cmdUpper.hasPrefix($0) }
        let isProductionOnly = productionConfirmCommands.contains { cmdUpper.hasPrefix($0) }

        if isAlwaysConfirm || (isProductionOnly && isProduction) {
            pendingCommand = cmd
            if isProduction {
                showProductionConfirm = true
            } else {
                showDangerousCommandAlert = true
            }
            return
        }

        input = ""
        Task { await tab.executeCommand(cmd) }
    }
}

struct ShellHistoryRow: View, Equatable {
    let entry: ShellHistoryEntry

    /// Without `Equatable`, SwiftUI re-evaluates every history row's body on
    /// each keystroke in the input field; this lets unchanged rows skip their
    /// body (and the highlighter call) entirely.
    static nonisolated func == (lhs: ShellHistoryRow, rhs: ShellHistoryRow) -> Bool {
        lhs.entry == rhs.entry
    }

    private var statusColor: Color {
        entry.isError ? AppColor.shellError : AppColor.shellSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            // Command line: prompt + highlighted command + status + time
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Text("›")
                    .font(AppFont.dataCell)
                    .fontWeight(.bold)
                    .foregroundStyle(AppColor.shellPrompt)

                Text(TreeSitterBashHighlighter.shared.highlight(entry.command))
                    .font(AppFont.dataCell)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(statusColor)

                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Output block
            Text(entry.result)
                .font(AppFont.monoSubheadline)
                .foregroundStyle(entry.isError ? AppColor.shellError : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.small)
                .background(AppColor.shellOutputBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.small)
        .background(.background)
    }
}
