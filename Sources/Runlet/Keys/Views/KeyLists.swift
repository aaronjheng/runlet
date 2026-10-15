import SwiftUI

// MARK: - Key Lists

/// Keys shown per namespace page in tree view. Shared by the node view
/// (which slices its rows) and KeysView (which walks the visible order for
/// keyboard navigation).
let keyNamespacePageSize = 500

/// Flat and namespace-grouped key lists for the Keys pane's left panel.
private func scrollToKey(_ key: String?, using proxy: ScrollViewProxy) {
    guard let key else { return }
    proxy.scrollTo(key, anchor: .top)
}

struct KeyFlatList: View {
    let keys: [RedisKeyEntry]
    @Binding var selectedKey: RedisKeyEntry?
    let scrollTargetKey: String?
    let onLoadMoreKeys: () -> Void
    let onDeleteKey: (RedisKeyEntry) -> Void
    let onCopyKey: (RedisKeyEntry) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(keys) { entry in
                        KeyRow(entry: entry)
                            .fullWidthListRow(selected: selectedKey?.key == entry.key)
                            .clickCursor()
                            .id(entry.key)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedKey = entry }
                            .contextMenu {
                                Button("Copy Key") {
                                    onCopyKey(entry)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    onDeleteKey(entry)
                                }
                            }
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
            } action: { _, distanceFromBottom in
                // Incremental paging: fetch the next SCAN batch as the list
                // approaches the bottom. The callback coalesces via TabState's
                // scan re-entrancy guard, so repeat firings are harmless.
                if distanceFromBottom < 200 && !keys.isEmpty {
                    onLoadMoreKeys()
                }
            }
            .onAppear {
                scrollToKey(scrollTargetKey, using: proxy)
            }
            .onChange(of: scrollTargetKey) { _, newValue in
                scrollToKey(newValue, using: proxy)
            }
        }
    }
}

struct KeyNamespaceList: View {
    let tree: KeyNamespaceTree
    @Binding var selectedKey: RedisKeyEntry?
    @Binding var expandedNamespaces: Set<String>
    @Binding var namespacePageCounts: [String: Int]
    let scrollTargetKey: String?
    let onLoadMoreKeys: () -> Void
    let onDeleteKey: (RedisKeyEntry) -> Void
    let onCopyKey: (RedisKeyEntry) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tree.rootKeys) { entry in
                        KeyRow(entry: entry)
                            .fullWidthListRow(selected: selectedKey?.key == entry.key)
                            .clickCursor()
                            .id(entry.key)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedKey = entry }
                            .contextMenu {
                                Button("Copy Key") {
                                    onCopyKey(entry)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    onDeleteKey(entry)
                                }
                            }
                    }

                    ForEach(tree.namespaces) { namespace in
                        KeyNamespaceNodeView(
                            namespace: namespace,
                            depth: 0,
                            separator: tree.separator,
                            selectedKey: $selectedKey,
                            expandedNamespaces: $expandedNamespaces,
                            namespacePageCounts: $namespacePageCounts,
                            onLoadMoreKeys: onLoadMoreKeys,
                            onDeleteKey: onDeleteKey,
                            onCopyKey: onCopyKey
                        )
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
            } action: { _, distanceFromBottom in
                if distanceFromBottom < 200 && !tree.allKeys.isEmpty {
                    onLoadMoreKeys()
                }
            }
            .onAppear {
                scrollToKey(scrollTargetKey, using: proxy)
            }
            .onChange(of: scrollTargetKey) { _, newValue in
                scrollToKey(newValue, using: proxy)
            }
        }
    }
}

struct KeyNamespaceNodeView: View {
    let namespace: KeyNamespaceNode
    let depth: Int
    let separator: String
    @Binding var selectedKey: RedisKeyEntry?
    @Binding var expandedNamespaces: Set<String>
    @Binding var namespacePageCounts: [String: Int]
    let onLoadMoreKeys: () -> Void
    let onDeleteKey: (RedisKeyEntry) -> Void
    let onCopyKey: (RedisKeyEntry) -> Void

    private let pageSize = keyNamespacePageSize
    private var isExpanded: Bool { expandedNamespaces.contains(namespace.id) }

    /// Keys shown for this namespace: expanded page count × page size, capped
    /// at what the scan has loaded. "Show more" bumps the page count locally;
    /// the data is already in memory.
    private var loadedKeyCount: Int {
        let pages = max(namespacePageCounts[namespace.id] ?? 1, 1)
        return min(namespace.keys.count, pages * pageSize)
    }

    var body: some View {
        Group {
            folderRow
            if isExpanded {
                childrenSection
                keysSection
            }
        }
    }

    private var folderRow: some View {
        KeyNamespaceRow(namespace: namespace, isExpanded: isExpanded)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpansion)
            .clickCursor()
            .padding(.leading, CGFloat(depth) * AppSpacing.small)
            .fullWidthListRow(selected: false)
            .id("folder:\(namespace.id)")
    }

    private var childrenSection: some View {
        ForEach(namespace.children) { childNamespace in
            KeyNamespaceNodeView(
                namespace: childNamespace,
                depth: depth + 1,
                separator: separator,
                selectedKey: $selectedKey,
                expandedNamespaces: $expandedNamespaces,
                namespacePageCounts: $namespacePageCounts,
                onLoadMoreKeys: onLoadMoreKeys,
                onDeleteKey: onDeleteKey,
                onCopyKey: onCopyKey
            )
        }
    }

    private var keysSection: some View {
        let namespaceKeys = namespace.keys
        let displayedKeys = Array(namespaceKeys.prefix(loadedKeyCount))
        let hasMore = namespaceKeys.count > loadedKeyCount
        let childIndent = CGFloat(depth + 1) * AppSpacing.small
        return Group {
            ForEach(displayedKeys) { entry in
                KeyRow(entry: entry, displayName: KeyNamespaceTree.leafName(for: entry.key, separator: separator))
                    .padding(.leading, childIndent)
                    .fullWidthListRow(selected: selectedKey?.key == entry.key)
                    .clickCursor()
                    .id(entry.key)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedKey = entry }
                    .contextMenu {
                        Button("Copy Key") {
                            onCopyKey(entry)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            onDeleteKey(entry)
                        }
                    }
            }

            if hasMore {
                // Previously a dead end: keys beyond the first page were
                // unreachable. Bumping the page count reveals more from the
                // already-scanned data, so this needs no server round trip.
                Button {
                    namespacePageCounts[namespace.id, default: 1] += 1
                } label: {
                    HStack(spacing: AppSpacing.xSmall) {
                        Image(systemName: "chevron.down.circle")
                        Text("Show \(namespaceKeys.count - loadedKeyCount) more keys…")
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverBackground()
                .padding(.vertical, AppSpacing.xSmall)
                .padding(.leading, childIndent)
                .fullWidthListRow(selected: false)
                .id("more:\(namespace.id)")
            }
        }
    }

    private func toggleExpansion() {
        if isExpanded {
            expandedNamespaces.remove(namespace.id)
        } else {
            expandedNamespaces.insert(namespace.id)
        }
    }
}

struct KeyNamespaceRow: View {
    let namespace: KeyNamespaceNode
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary)
                .frame(width: AppSize.namespaceChevronWidth, alignment: .leading)
            Image(systemName: "folder")
                .foregroundStyle(.tint)
            Text(namespace.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(namespace.keyCount)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, AppSpacing.medium)
        .padding(.horizontal, AppSpacing.small)
        .accessibilityLabel("\(namespace.name), \(namespace.keyCount) keys")
    }
}
