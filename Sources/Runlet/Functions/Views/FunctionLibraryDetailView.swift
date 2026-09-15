import SwiftUI

// MARK: - Function Library Detail View

struct FunctionLibraryDetailView: View {
    @Environment(TabState.self) private var tab
    let library: RedisFunctionLibrary

    @State private var showingDeleteConfirm = false
    @State private var productionConfirmText = ""
    @State private var showingEditSheet = false
    @State private var showingCallSheet = false
    @State private var isFunctionsExpanded = false

    private var isProduction: Bool {
        tab.selectedConnection?.environment == .production
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !library.functions.isEmpty {
                functionsSection
                Divider()
            }
            ScrollView {
                SelectableText(
                    text: library.code,
                    font: AppFont.dataCellNSFont,
                    tokenizer: TreeSitterLuaHighlighter.shared
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.large)
            }
            .onTapGesture(count: 2) {
                showingEditSheet = true
            }
            .overlay(alignment: .topTrailing) {
                Button("Edit Source", systemImage: "square.and.pencil") {
                    showingEditSheet = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle(weight: .semibold))
                .help("Edit library source (or double-click code)")
                .padding(AppSpacing.large)
            }

            Divider()

            PanelFooterBar {
                StatusFooterView(countText: footerText)
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $showingEditSheet) {
            LuaEditorView(mode: .edit(library))
        }
        .sheet(isPresented: $showingCallSheet) {
            FunctionCallView(library: library)
        }
        .confirmationDialog(
            "Delete library \"\(library.name)\"",
            isPresented: Binding(
                get: { showingDeleteConfirm && !isProduction },
                set: { showingDeleteConfirm = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await tab.deleteFunctionLibrary(name: library.name)
                    } catch {
                        tab.functionsError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let nodes = library.nodes, !nodes.isEmpty {
                Text(
                    "This will delete the library from \(nodes.count) primary node(s). This action cannot be undone."
                )
            } else {
                Text("This action cannot be undone.")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { showingDeleteConfirm && isProduction },
                set: {
                    if !$0 {
                        showingDeleteConfirm = false
                        productionConfirmText = ""
                    }
                }
            )
        ) {
            ProductionConfirmView(
                title: "Delete library \"\(library.name)\"",
                message: (library.nodes ?? []).isEmpty
                    ? "This will permanently delete the library. This action cannot be undone."
                    : "This will permanently delete the library from \((library.nodes ?? []).count)"
                        + "primary node(s). This action cannot be undone.",
                confirmText: "DELETE",
                confirmButtonTitle: "Delete",
                input: $productionConfirmText,
                onConfirm: {
                    Task {
                        do {
                            try await tab.deleteFunctionLibrary(name: library.name)
                        } catch {
                            tab.functionsError = error.localizedDescription
                        }
                    }
                    showingDeleteConfirm = false
                    productionConfirmText = ""
                },
                onCancel: {
                    showingDeleteConfirm = false
                    productionConfirmText = ""
                }
            )
            .presentationSizing(.form)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                HStack(spacing: AppSpacing.small) {
                    Badge(text: library.engine, isLoading: library.engine.isEmpty)
                    Text(library.name)
                        .font(.title3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: AppSpacing.compact) {
                    HStack(spacing: AppSpacing.xxSmall) {
                        Image(systemName: "number")
                        Text("\(library.functionCount) function\(library.functionCount == 1 ? "" : "s")")
                    }
                    .foregroundStyle(.secondary)
                    if library.isReadOnly {
                        Badge(
                            text: "Read-only",
                            foregroundColor: AppColor.success,
                            backgroundColor: AppColor.badgeBackground(AppColor.success)
                        )
                    }
                    if let nodes = library.nodes, !nodes.isEmpty {
                        HStack(spacing: AppSpacing.xSmall) {
                            Image(systemName: "server.rack")
                            Text(nodes.map(\.address).joined(separator: ", "))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(nodes.map(\.address).joined(separator: ", "))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            Spacer(minLength: 0)
            HStack(spacing: AppSpacing.small) {
                Button {
                    showingCallSheet = true
                } label: {
                    Label("Call", systemImage: "play")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(library.functions.isEmpty)
                .help("Run a function (FCALL)")
                DeleteIconButton(action: { showingDeleteConfirm = true }, helpText: "Delete library")
                    .toolbarCapsule()
            }
        }
        .padding(AppSpacing.small)
    }

    // MARK: Footer

    private var footerText: String {
        let functionsText = "\(library.functionCount) function\(library.functionCount == 1 ? "" : "s")"
        let lineCount = library.code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return "\(functionsText) \u{00B7} \(lineCount) lines"
    }

    // MARK: Functions

    private var functionsSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isFunctionsExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isFunctionsExpanded ? 90 : 0))
                    Image(systemName: "curlybraces")
                        .foregroundStyle(.tint)
                    Text("Functions")
                        .font(.headline)
                    Spacer(minLength: 0)
                    Text("\(library.functionCount)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(AppSpacing.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverBackground()
            .help(isFunctionsExpanded ? "Hide functions" : "Show functions")

            if isFunctionsExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(library.functions.enumerated()), id: \.element.id) { index, function in
                        functionRow(function)
                        if index < library.functions.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func functionRow(_ function: RedisFunction) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.small) {
            Image(systemName: "f.cursive")
                .foregroundStyle(.tint)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(function.name)
                        .font(AppFont.monoSubheadline)
                    if function.isReadOnly {
                        Badge(
                            text: "no-writes",
                            foregroundColor: AppColor.success,
                            backgroundColor: AppColor.badgeBackground(AppColor.success)
                        )
                    }
                }
                if let description = function.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.small)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Function Name") {
                copyToPasteboard(function.name)
            }
            Button("Copy FCALL Command") {
                copyToPasteboard("FCALL \(function.name) 0")
            }
        }
        .help(function.name)
    }
}
