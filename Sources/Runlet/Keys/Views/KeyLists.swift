import SwiftUI

// MARK: - Key Lists

/// Flat and namespace-grouped key lists for the Keys pane's left panel.
private func scrollToKey(_ key: String?, using proxy: ScrollViewProxy) {
    guard let key else { return }
    proxy.scrollTo(key, anchor: .top)
}

struct KeyFlatList: View {
    let keys: [RedisKeyEntry]
    @Binding var selectedKey: RedisKeyEntry?
    let scrollTargetKey: String?
    let onDeleteKey: (RedisKeyEntry) -> Void
    let onCopyKey: (RedisKeyEntry) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(keys) { entry in
                        KeyRow(entry: entry)
                            .fullWidthListRow(selected: selectedKey?.key == entry.key)
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
    let scrollTargetKey: String?
    let onDeleteKey: (RedisKeyEntry) -> Void
    let onCopyKey: (RedisKeyEntry) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tree.rootKeys) { entry in
                        KeyRow(entry: entry)
                            .fullWidthListRow(selected: selectedKey?.key == entry.key)
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
                            onDeleteKey: onDeleteKey,
                            onCopyKey: onCopyKey
                        )
                    }
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
    let onDeleteKey: (RedisKeyEntry) -> Void
    let onCopyKey: (RedisKeyEntry) -> Void

    private let pageSize = 500
    private var isExpanded: Bool { expandedNamespaces.contains(namespace.id) }

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
                onDeleteKey: onDeleteKey,
                onCopyKey: onCopyKey
            )
        }
    }

    private var keysSection: some View {
        let namespaceKeys = namespace.keys
        let displayedKeys = Array(namespaceKeys.prefix(pageSize))
        let hasMore = namespaceKeys.count > pageSize
        let childIndent = CGFloat(depth + 1) * AppSpacing.small
        return Group {
            ForEach(displayedKeys) { entry in
                KeyRow(entry: entry, displayName: KeyNamespaceTree.leafName(for: entry.key, separator: separator))
                    .padding(.leading, childIndent)
                    .fullWidthListRow(selected: selectedKey?.key == entry.key)
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
                HStack {
                    Spacer()
                    Text("\(namespaceKeys.count - pageSize) more keys…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
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
