import SwiftUI

// MARK: - Functions View

struct FunctionsView: View {
    @Environment(TabState.self) private var tab
    @State private var searchText = ""
    @State private var typeFilter = ""
    @State private var showingLoadSheet = false
    @State private var libraryPendingDeletion: RedisFunctionLibrary?
    @State private var productionConfirmText = ""

    private var isProduction: Bool {
        tab.selectedConnection?.environment == .production
    }
    private var isClusterMode: Bool {
        tab.selectedConnection?.mode == .cluster || !tab.clusterNodes.isEmpty
    }

    private var filteredLibraries: [RedisFunctionLibrary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tab.functionLibraries.filter { library in
            let matchesQuery = query.isEmpty || library.name.lowercased().contains(query)
            let matchesType = typeFilter.isEmpty || (typeFilter == "readonly") == library.isReadOnly
            return matchesQuery && matchesType
        }
    }

    /// The currently selected library, freshly resolved against the latest fetch
    /// so the detail view always reflects reloaded data.
    private var displayedLibrary: RedisFunctionLibrary? {
        guard let selected = tab.selectedFunctionLibrary else { return nil }
        return tab.functionLibraries.first { $0.name == selected.name }
    }

    var body: some View {
        @Bindable var tab = tab
        VStack(spacing: 0) {
            header

            if let error = tab.functionsError {
                ErrorBanner(message: error, dismissAction: { tab.functionsError = nil })
            }

            Divider()

            content
        }
        .task {
            if tab.serverInfo.isEmpty { await tab.loadServerInfo() }
            if tab.supportsFunctions { await tab.fetchFunctionLibraries() }
        }
        .sheet(isPresented: $showingLoadSheet) {
            LuaEditorView(mode: .create)
        }
        .confirmationDialog(
            "Delete library \"\(libraryPendingDeletion?.name ?? "")\"",
            isPresented: Binding(
                get: { libraryPendingDeletion != nil && !isProduction },
                set: { isPresented in
                    if !isPresented { libraryPendingDeletion = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let library = libraryPendingDeletion {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await tab.deleteFunctionLibrary(name: library.name)
                        } catch {
                            tab.functionsError = error.localizedDescription
                        }
                    }
                    libraryPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { libraryPendingDeletion = nil }
        } message: {
            if let nodes = libraryPendingDeletion?.nodes, !nodes.isEmpty {
                Text(
                    "This will delete the library from \(nodes.count) primary node(s). This action cannot be undone."
                )
            } else {
                Text("This action cannot be undone.")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { libraryPendingDeletion != nil && isProduction },
                set: { isPresented in
                    if !isPresented {
                        libraryPendingDeletion = nil
                        productionConfirmText = ""
                    }
                }
            )
        ) {
            if let library = libraryPendingDeletion {
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
                        libraryPendingDeletion = nil
                        productionConfirmText = ""
                    },
                    onCancel: {
                        libraryPendingDeletion = nil
                        productionConfirmText = ""
                    }
                )
                .presentationSizing(.form)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var tab = tab
        return HStack(spacing: AppSpacing.small) {
            FilterField("Filter libraries", text: $searchText)
                .frame(maxWidth: .infinity)

            Button {
                showingLoadSheet = true
            } label: {
                Label("Load", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!tab.supportsFunctions)
        }
        .panelToolbar(horizontalPadding: AppSpacing.small)
    }

    private var unsupportedFunctionsDescription: String {
        if let version = tab.serverInfo["Server"]?["redis_version"], !version.isEmpty {
            return "Detected Redis \(version) — upgrade to 7.0 or later for Functions."
        }
        return "Redis Functions are available in Redis 7.0 and later."
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if tab.activeSession?.isConnected != true {
            emptyState("Not connected", "Connect to a Redis server to manage functions")
        } else if !tab.supportsFunctions {
            emptyState(
                "Redis 7.0+ required",
                unsupportedFunctionsDescription
            )
        } else if tab.isLoadingFunctions && tab.functionLibraries.isEmpty {
            Spacer()
            LoadingState(message: "Loading functions…")
            Spacer()
        } else {
            PersistentSplitView(
                autosaveName: "app.runlet.functionsSplit",
                leftMinWidth: 220,
                rightMinWidth: 320
            ) {
                libraryList
            } right: {
                if let library = displayedLibrary {
                    FunctionLibraryDetailView(library: library)
                } else {
                    Spacer()
                    ContentUnavailableView(
                        "No library selected",
                        systemImage: "curlybraces",
                        description: Text("Select a library to view its functions and source code.")
                    )
                    Spacer()
                }
            }
        }
    }

    // MARK: Library list

    private var libraryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                OptionsPicker(
                    "Filter by library type",
                    selection: $typeFilter,
                    options: ["", "readonly", "readwrite"],
                    label: { typeFilterTitle($0) }
                )
                .frame(height: AppSize.refreshControlHeight)

                Spacer()

                if tab.isLoadingFunctions {
                    ProgressView()
                        .controlSize(.small)
                }

                RefreshButton(isLoading: tab.isLoadingFunctions) {
                    Task { await tab.fetchFunctionLibraries() }
                }
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.mini)

            Divider()

            Group {
                if filteredLibraries.isEmpty {
                    Spacer()
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "No libraries",
                            systemImage: "curlybraces",
                            description: Text("Load a function library to get started.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No matching libraries",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different filter.")
                        )
                        Button("Clear Filter") {
                            searchText = ""
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, AppSpacing.small)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredLibraries) { library in
                                FunctionLibraryRow(library: library)
                                    .fullWidthListRow(selected: tab.selectedFunctionLibrary?.name == library.name)
                                    .id(library.name)
                                    .contentShape(Rectangle())
                                    .onTapGesture { tab.selectedFunctionLibrary = library }
                                    .contextMenu {
                                        Button("Delete", role: .destructive) {
                                            libraryPendingDeletion = library
                                        }
                                    }
                            }
                        }
                    }
                }
            }

            Divider()

            PanelFooterBar {
                StatusFooterView(countText: footerCountText, sizeText: footerSizeText)
                Spacer()
            }
        }
    }

    // MARK: Helpers

    private var footerCountText: String {
        let total = tab.functionLibraries.count
        let filtered = filteredLibraries.count
        if (searchText.isEmpty && typeFilter.isEmpty) || filtered == total {
            return pluralizedCount(total, singular: "library", plural: "libraries")
        }
        return "Showing \(filtered) of " + pluralizedCount(total, singular: "library", plural: "libraries")
    }

    private var footerSizeText: String? {
        guard isClusterMode else { return nil }
        let primaryCount = tab.clusterNodes.filter { $0.role == .primary }.count
        guard primaryCount > 0 else { return nil }
        return pluralizedCount(primaryCount, singular: "primary", plural: "primaries")
    }

    private func typeFilterTitle(_ filter: String) -> String {
        switch filter {
        case "readonly": return "Read-only"
        case "readwrite": return "Read-write"
        default: return "All"
        }
    }

    private func emptyState(_ title: String, _ description: String) -> some View {
        VStack {
            Spacer()
            ContentUnavailableView(title, systemImage: "curlybraces", description: Text(description))
            Spacer()
        }
    }
}

private struct FunctionLibraryRow: View {
    let library: RedisFunctionLibrary
    @Environment(\.listRowIsSelected) private var isSelected

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Text(library.engine)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isSelected ? AppColor.onSelectionSecondary : .secondary)
                .lineLimit(1)
                .frame(width: AppSize.typeBadgeWidth, alignment: .center)
                .padding(.vertical, AppSpacing.xxSmall)
                .background(isSelected ? AppColor.selectionBadgeBackground : AppColor.subtleBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            Text(library.name)
                .font(.body)
                .foregroundStyle(isSelected ? AppColor.onSelection : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, AppSpacing.medium)
        .padding(.leading, AppSpacing.small)
        .padding(.trailing, AppSpacing.small)
        .help(library.name)
        .accessibilityLabel(library.name)
    }
}
