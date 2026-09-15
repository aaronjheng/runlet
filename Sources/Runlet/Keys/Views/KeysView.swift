import SwiftUI

struct KeysView: View {
    @Environment(TabState.self) var tab
    @State private var searchText = ""
    @State private var showingAddKey = false
    @State private var keyPendingDeletion: RedisKeyEntry?
    @State var newKeyName = ""
    @State var newKeyType = "string"
    @State var newKeyValue = ""
    @State private var expandedNamespaces: Set<String> = []
    @State var keyListScrollTarget: String?
    @State private var productionConfirmText = ""
    @State private var autoRefreshInterval: TimeInterval = 0
    @State private var deleteFeedbackTrigger = false
    @State private var copyFeedbackTrigger = false

    let listScanCount = 500
    let treeScanCount = 10_000

    var body: some View {
        @Bindable var tab = tab

        VStack(spacing: 0) {
            // MARK: Header Bar
            HStack(spacing: AppSpacing.small) {
                FilterField("Filter by key pattern (e.g. user:*)", text: $searchText) {
                    tab.keyFilter = searchText.isEmpty ? "*" : searchText
                    tab.keyScanCount = currentScanCount
                    Task { await tab.scanKeys(reset: true) }
                }
                .frame(maxWidth: .infinity)

                Button {
                    newKeyName = ""
                    newKeyType = "string"
                    newKeyValue = ""
                    showingAddKey = true
                } label: {
                    Label("Add Key", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Add a new key")
            }
            .panelToolbar(horizontalPadding: AppSpacing.small)

            Divider()

            if let error = tab.connectionError {
                ErrorBanner(message: error, dismissAction: { tab.connectionError = nil })
                Divider()
            }

            PersistentSplitView(
                leftMinWidth: 250,
                rightMinWidth: 250
            ) {
                // MARK: Left Panel
                VStack(spacing: 0) {
                    HStack(spacing: AppSpacing.mini) {
                        OptionsPicker(
                            "Filter by key type",
                            selection: $tab.keyTypeFilter,
                            options: ["", "string", "list", "hash", "set", "zset"],
                            label: { typeFilterTitle($0) }
                        )
                        .frame(height: AppSize.refreshControlHeight)

                        Spacer()

                        BinaryTogglePicker(
                            selection: Binding(
                                get: { tab.isNamespaceGroupingEnabled },
                                set: { isEnabled in
                                    guard tab.isNamespaceGroupingEnabled != isEnabled else { return }
                                    tab.isNamespaceGroupingEnabled = isEnabled
                                    tab.keyScanCount = isEnabled ? treeScanCount : listScanCount
                                    expandedNamespaces = []
                                    Task { await tab.scanKeys(reset: true) }
                                }
                            ),
                            first: false,
                            second: true,
                            firstHelp: "Flat list",
                            secondHelp: "Group by namespace",
                            firstLabel: { Image(systemName: "list.bullet") },
                            secondLabel: { Image(systemName: "folder") }
                        )
                        .frame(width: AppSize.binaryToggleWidth)

                        RefreshControl(
                            autoRefreshInterval: $autoRefreshInterval,
                            isLoading: tab.isLoadingKeys,
                            intervals: AutoRefreshInterval.options
                        ) {
                            tab.keyScanCount = currentScanCount
                            Task { await tab.scanKeys(reset: true) }
                        }
                    }
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.vertical, AppSpacing.mini)

                    Divider()

                    let displayedKeys = filteredKeys

                    if tab.isLoadingKeys && tab.keys.isEmpty {
                        Spacer()
                        LoadingState(message: "Scanning keys…")
                        Spacer()
                    } else if tab.keys.isEmpty {
                        Spacer()
                        ContentUnavailableView(
                            isFiltering ? "No matching keys" : "No keys found",
                            systemImage: isFiltering ? "magnifyingglass" : "key.slash",
                            description: Text(isFiltering ? filterHint : "This database has no keys")
                        )
                        loadMoreOrScanningView
                        Spacer()
                    } else if displayedKeys.isEmpty {
                        Spacer()
                        ContentUnavailableView(
                            "No matching keys",
                            systemImage: "magnifyingglass",
                            description: Text(filterHint)
                        )
                        loadMoreOrScanningView
                        Spacer()
                    } else {
                        Group {
                            if tab.isNamespaceGroupingEnabled {
                                KeyNamespaceList(
                                    tree: tab.namespaceTree(for: displayedKeys),
                                    selectedKey: $tab.selectedKey,
                                    expandedNamespaces: $expandedNamespaces,
                                    scrollTargetKey: keyListScrollTarget,
                                    onDeleteKey: { keyPendingDeletion = $0 },
                                    onCopyKey: copyKeyToPasteboard
                                )
                            } else {
                                KeyFlatList(
                                    keys: displayedKeys,
                                    selectedKey: $tab.selectedKey,
                                    scrollTargetKey: keyListScrollTarget,
                                    onDeleteKey: { keyPendingDeletion = $0 },
                                    onCopyKey: copyKeyToPasteboard
                                )
                            }
                        }
                        .onChange(of: tab.selectedKey) { _, newValue in
                            if let key = newValue {
                                expandNamespaces(containing: key.key)
                                Task { await tab.selectKey(key) }
                            }
                        }

                        loadMoreOrScanningView
                    }

                    Divider()

                    PanelFooterBar {
                        StatusFooterView(
                            countText: keysFooterText(displayedCount: filteredKeys.count)
                        )
                        Spacer()
                    }
                }
            } right: {
                KeyDetailView()
            }
        }
        .sheet(isPresented: $showingAddKey) {
            AddKeySheet(
                keyName: $newKeyName,
                keyType: $newKeyType,
                keyValue: $newKeyValue,
                onSave: { name, type, value in
                    Task { await addKey(name: name, type: type, value: value) }
                    showingAddKey = false
                },
                onCancel: { showingAddKey = false }
            )
        }
        .confirmationDialog(
            "Delete Key",
            isPresented: Binding(
                get: { keyPendingDeletion != nil && !isProduction },
                set: { isPresented in
                    if !isPresented { keyPendingDeletion = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let key = keyPendingDeletion {
                Button("Delete", role: .destructive) {
                    Task { await tab.deleteKey(key) }
                    keyPendingDeletion = nil
                    deleteFeedbackTrigger.toggle()
                }
            }
            Button("Cancel", role: .cancel) { keyPendingDeletion = nil }
        } message: {
            if let key = keyPendingDeletion {
                Text("This permanently deletes \(key.key).")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { keyPendingDeletion != nil && isProduction },
                set: { isPresented in
                    if !isPresented {
                        keyPendingDeletion = nil
                        productionConfirmText = ""
                    }
                }
            )
        ) {
            if let key = keyPendingDeletion {
                ProductionConfirmView(
                    title: "Delete Key",
                    message: "This permanently deletes \(key.key).",
                    confirmText: "DELETE",
                    confirmButtonTitle: "Delete",
                    input: $productionConfirmText,
                    onConfirm: {
                        Task { await tab.deleteKey(key) }
                        keyPendingDeletion = nil
                        productionConfirmText = ""
                        deleteFeedbackTrigger.toggle()
                    },
                    onCancel: {
                        keyPendingDeletion = nil
                        productionConfirmText = ""
                    }
                )
                .presentationSizing(.form)
            }
        }
        .onAppear {
            tab.keyScanCount = currentScanCount
            searchText = tab.keyFilter == "*" ? "" : tab.keyFilter
        }
        .sensoryFeedback(.success, trigger: deleteFeedbackTrigger)
        .sensoryFeedback(.success, trigger: copyFeedbackTrigger)
        .task(id: autoRefreshTaskID) {
            guard autoRefreshInterval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(autoRefreshInterval))
                guard !Task.isCancelled, !tab.isLoadingKeys else { continue }
                tab.keyScanCount = currentScanCount
                await tab.scanKeys(reset: true)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    var loadMoreOrScanningView: some View {
        if tab.hasMoreKeys {
            if tab.isLoadingKeys {
                HStack(spacing: AppSpacing.mini) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(AppSpacing.small)
            } else {
                Button("Load More") {
                    tab.keyScanCount = currentScanCount
                    Task { await tab.scanKeys() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(AppSpacing.small)
            }
        }
    }

    // MARK: - Helpers

    var filteredKeys: [RedisKeyEntry] {
        tab.keys.filter { tab.keyTypeFilter.isEmpty || $0.type.isEmpty || $0.type == tab.keyTypeFilter }
    }

    var isFiltering: Bool {
        !searchText.isEmpty || !tab.keyTypeFilter.isEmpty
    }

    var filterHint: String {
        searchText.isEmpty ? "Try a different type filter" : "Try a different filter pattern"
    }

    func typeFilterTitle(_ filter: String) -> String {
        filter.isEmpty ? "All" : redisKeyTypeTitle(filter)
    }

    var currentScanCount: Int {
        tab.isNamespaceGroupingEnabled ? treeScanCount : listScanCount
    }

    var isProduction: Bool {
        tab.selectedConnection?.environment == .production
    }

    var autoRefreshTaskID: String {
        "\(autoRefreshInterval)"
    }

    func copyKeyToPasteboard(_ entry: RedisKeyEntry) {
        copyToPasteboard(entry.key)
        copyFeedbackTrigger.toggle()
    }

    func expandNamespaces(containing key: String) {
        var namespacePath: [String] = []
        for namespace in KeyNamespaceTree.namespaceSegments(for: key, separator: tab.namespaceSeparator) {
            namespacePath.append(namespace)
            expandedNamespaces.insert(namespacePath.joined(separator: tab.namespaceSeparator))
        }
    }

    func keysFooterText(displayedCount: Int) -> String {
        let totalText = tab.keyTotalCount.map(String.init) ?? "unknown"
        let limitText = tab.keyScanLimitReached ? " · threshold reached" : ""
        let showsScanProgress = tab.keyFilter != "*" || !tab.keyTypeFilter.isEmpty || tab.isNamespaceGroupingEnabled

        if showsScanProgress {
            return "Showing \(displayedCount) of \(totalText) · scanned \(tab.keyScannedCount)\(limitText)"
        }
        return "\(tab.keys.count) of \(totalText) loaded\(limitText)"
    }
}
