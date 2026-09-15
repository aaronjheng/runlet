import SwiftUI

struct ServerInfoView: View {
    @Environment(TabState.self) private var tab

    var sections: [String] {
        tab.serverInfo.keys
            .filter { $0 != "Modules" }
            .sorted()
    }

    @State private var showTopology = false

    private var isClusterMode: Bool {
        tab.selectedConnection?.mode == .cluster || !tab.clusterNodes.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: AppSpacing.medium) {
                Spacer()
                if tab.isLoadingServerInfo {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await tab.loadServerInfo() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(tab.isLoadingServerInfo)
            }
            .panelToolbar(horizontalPadding: AppSpacing.small)

            Divider()

            if let error = tab.serverInfoError {
                ErrorBanner(message: error, dismissAction: { tab.serverInfoError = nil })
                Divider()
            }

            if isClusterMode && !tab.clusterNodes.isEmpty {
                clusterInfoView
            } else if tab.serverInfo.isEmpty {
                Spacer()
                if tab.isLoadingServerInfo {
                    LoadingState(message: "Loading server info…")
                } else {
                    ContentUnavailableView(
                        "No server info loaded",
                        systemImage: "info.circle",
                        description: Text("Click Refresh to load server information")
                    )
                    Button("Refresh") {
                        Task { await tab.loadServerInfo() }
                    }
                    .padding(.top, AppSpacing.small)
                }
                Spacer()
            } else {
                serverInfoList
            }
            Divider()
            PanelFooterBar {
                StatusFooterView(
                    countText: "\(sections.count) sections",
                    sizeText: tab.serverCapabilities.isEmpty ? nil : "\(tab.serverCapabilities.count) modules"
                )
                Spacer()
            }
        }
    }

    private var clusterInfoView: some View {
        @Bindable var tab = tab

        return VStack(spacing: 0) {
            clusterSummaryBar
            Divider()
            if showTopology {
                ClusterTopologyView(
                    nodes: tab.clusterNodes,
                    selectedEndpoint: $tab.selectedServerInfoNode,
                    onSelectNode: { endpoint in
                        Task { await tab.selectServerInfoNode(endpoint) }
                        showTopology = false
                    }
                )
            } else {
                HStack(spacing: 0) {
                    clusterNodeList
                        .frame(width: 280)
                    Divider()
                    VStack(spacing: 0) {
                        selectedNodeHeader
                        Divider()
                        serverInfoList
                    }
                }
            }
        }
    }

    private var clusterSummaryBar: some View {
        HStack(spacing: AppSpacing.xLarge) {
            summaryItem("State", tab.clusterInfo["cluster_state"] ?? "-")
            summaryItem("Nodes", tab.clusterInfo["cluster_known_nodes"] ?? "\(tab.clusterNodes.count)")
            summaryItem("Primaries", "\(tab.clusterNodes.filter { $0.role == .primary }.count)")
            summaryItem("Replicas", "\(tab.clusterNodes.filter { $0.role == .replica }.count)")
            summaryItem("Slots", tab.clusterInfo["cluster_slots_assigned"] ?? "\(assignedSlotCount)")
            summaryItem("OK Slots", tab.clusterInfo["cluster_slots_ok"] ?? "-")
            Spacer()
            if isClusterMode && !tab.clusterNodes.isEmpty {
                BinaryTogglePicker(
                    selection: $showTopology,
                    first: false,
                    second: true,
                    firstHelp: "List view",
                    secondHelp: "Topology view",
                    firstLabel: { Image(systemName: "list.bullet") },
                    secondLabel: { Image(systemName: "square.grid.2x2") }
                )
                .frame(width: AppSize.binaryToggleWidth)
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.small)
        .background(AppColor.controlBackground)
    }

    private var clusterNodeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nodes")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    ForEach(tab.clusterNodes) { node in
                        Button {
                            Task { await tab.selectServerInfoNode(node.endpoint) }
                        } label: {
                            clusterNodeRow(node)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppSpacing.small)
                .padding(.bottom, AppSpacing.small)
            }
        }
        .background(AppColor.controlBackground)
    }

    private var selectedNodeHeader: some View {
        HStack(spacing: AppSpacing.medium) {
            if let node = selectedNode {
                Image(systemName: node.role == .primary ? "server.rack" : "externaldrive.connected.to.line.below")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text(node.endpoint.address)
                        .font(.headline)
                    Text(nodeSubtitle(node))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("No node selected")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.compact)
    }

    private var serverInfoList: some View {
        List {
            capabilitiesSection

            ForEach(sections, id: \.self) { section in
                Section(header: Text(section)) {
                    if let items = tab.serverInfo[section] {
                        ForEach(items.keys.sorted(), id: \.self) { key in
                            infoRow(key, items[key] ?? "")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if tab.isLoadingServerInfo && !tab.serverInfo.isEmpty {
                VStack(spacing: AppSpacing.small) {
                    ProgressView()
                    Text("Loading node info…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(AppSpacing.large)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppRadius.medium))
                .padding(AppSpacing.large)
            }
        }
    }

    private var capabilitiesSection: some View {
        Section(header: Text("Capabilities")) {
            infoRow("redis", tab.serverInfo["Server"]?["redis_version"] ?? "-")
            infoRow("mode", capabilityMode)

            if tab.serverCapabilities.isEmpty {
                infoRow("modules", "No modules loaded")
            } else {
                ForEach(tab.serverCapabilities) { capability in
                    capabilityRow(capability)
                }
            }
        }
    }

    private var selectedNode: RedisClusterNodeSummary? {
        guard let endpoint = tab.selectedServerInfoNode else { return nil }
        return tab.clusterNodes.first { $0.endpoint == endpoint }
    }

    private var assignedSlotCount: Int {
        tab.clusterNodes
            .filter { $0.role == .primary }
            .reduce(0) { $0 + $1.coveredSlotCount }
    }

    private var capabilityMode: String {
        if isClusterMode || tab.serverInfo["Cluster"]?["cluster_enabled"] == "1" {
            return "Cluster"
        }
        return "Standalone"
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(AppFont.monoSubheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 160, alignment: .leading)
            Spacer()
            Text(value)
                .font(AppFont.monoSubheadline)
                .textSelection(.enabled)
        }
    }

    private func capabilityRow(_ capability: RedisServerCapability) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack(alignment: .firstTextBaseline) {
                Text(capability.name)
                    .font(AppFont.monoSubheadline)
                    .foregroundStyle(.primary)
                    .frame(minWidth: 160, alignment: .leading)
                    .textSelection(.enabled)
                Spacer()
                Text(capability.version ?? "-")
                    .font(AppFont.monoSubheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !capability.details.isEmpty {
                Text(capabilityDetails(capability))
                    .font(AppFont.monoSubheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, AppSpacing.xxSmall)
    }

    private func clusterNodeRow(_ node: RedisClusterNodeSummary) -> some View {
        let isSelected = tab.selectedServerInfoNode == node.endpoint

        return HStack(alignment: .top, spacing: AppSpacing.small) {
            Image(systemName: node.role == .primary ? "server.rack" : "externaldrive.connected.to.line.below")
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                Text(node.endpoint.address)
                    .font(AppFont.monoSubheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(nodeSubtitle(node))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.mini)
        .background(isSelected ? AppColor.selectionBackground : Color.clear)
        .hoverBackground()
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
        .help("\(node.endpoint.address) — select to load node info")
    }

    private func summaryItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppFont.monoSubheadline)
                .textSelection(.enabled)
        }
    }

    private func nodeSubtitle(_ node: RedisClusterNodeSummary) -> String {
        switch node.role {
        case .primary:
            return "Primary · slots \(node.slotSummary)"
        case .replica:
            return "Replica of \(node.replicaOf?.address ?? "-")"
        }
    }

    private func capabilityDetails(_ capability: RedisServerCapability) -> String {
        capability.details.map { "\($0.name)=\($0.value)" }.joined(separator: " · ")
    }
}
