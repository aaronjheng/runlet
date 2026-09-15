import SwiftUI

// MARK: - Cluster Topology View

struct ClusterTopologyView: View {
    let nodes: [RedisClusterNodeSummary]
    @Binding var selectedEndpoint: RedisEndpoint?
    let onSelectNode: (RedisEndpoint) -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = computeLayout(in: geometry.size)
            ZStack {
                // Connection lines
                ForEach(layout.lines) { line in
                    Path { path in
                        path.move(to: line.from)
                        path.addLine(to: line.to)
                    }
                    .stroke(line.color, style: StrokeStyle(lineWidth: 1.5, dash: [AppSpacing.xSmall, AppSpacing.xSmall]))
                }

                // Nodes
                ForEach(layout.nodes) { item in
                    Button {
                        onSelectNode(item.node.endpoint)
                    } label: {
                        nodeView(item)
                    }
                    .buttonStyle(TopologyNodeButtonStyle())
                    .position(item.position)
                    .accessibilityLabel(nodeAccessibilityLabel(item.node) + (selectedEndpoint == item.node.endpoint ? ", selected" : ""))
                    .accessibilityAddTraits(selectedEndpoint == item.node.endpoint ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func nodeView(_ item: TopologyNodeItem) -> some View {
        let isSelected = selectedEndpoint == item.node.endpoint
        VStack(spacing: AppSpacing.xSmall) {
            ZStack {
                Circle()
                    .fill(item.color)
                    .frame(width: AppSize.topologyNodeDiameter, height: AppSize.topologyNodeDiameter)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.white : Color.clear, lineWidth: 3)
                    )
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 1)
                            .padding(3)
                    )
                    .shadow(color: item.color.opacity(0.4), radius: isSelected ? AppSpacing.small : AppSpacing.xSmall)

                Image(systemName: item.node.role == .primary ? "server.rack" : "externaldrive.connected.to.line.below")
                    .font(.title3)
                    .foregroundStyle(.white)
            }

            Text(item.node.endpoint.host)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 100)

            Text(item.node.endpoint.port.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(nodeTooltip(item.node))
    }

    private func nodeTooltip(_ node: RedisClusterNodeSummary) -> String {
        var parts: [String] = [
            "\(node.endpoint.address)",
            "Role: \(node.role.title)",
        ]
        if !node.slotRanges.isEmpty {
            parts.append("Slots: \(node.slotSummary)")
        }
        if let replicaOf = node.replicaOf {
            parts.append("Replica of: \(replicaOf.address)")
        }
        return parts.joined(separator: "\n")
    }

    private func nodeAccessibilityLabel(_ node: RedisClusterNodeSummary) -> String {
        "\(node.endpoint.address), \(node.role.title)"
    }

    private func computeLayout(in size: CGSize) -> TopologyLayout {
        let primaries = nodes.filter { $0.role == .primary }
        let replicas = nodes.filter { $0.role == .replica }

        let centerX = size.width / 2
        let centerY = size.height / 2
        let primaryRadius = min(size.width, size.height) * 0.25
        let replicaRadius = min(size.width, size.height) * 0.42

        var nodeItems: [TopologyNodeItem] = []
        var lines: [TopologyLine] = []

        // Layout primaries in a circle
        for (index, node) in primaries.enumerated() {
            let angle = (2 * .pi * Double(index) / Double(max(primaries.count, 1))) - .pi / 2
            let pos = CGPoint(
                x: centerX + CGFloat(cos(angle)) * primaryRadius,
                y: centerY + CGFloat(sin(angle)) * primaryRadius
            )
            nodeItems.append(TopologyNodeItem(node: node, position: pos, color: AppColor.info))
        }

        // Layout replicas in outer circle, connected to their primary
        for (index, node) in replicas.enumerated() {
            let replicaCount = Double(max(replicas.count, 1))
            let angle = (2 * .pi * Double(index) / replicaCount) - .pi / 2 + .pi / replicaCount
            let pos = CGPoint(
                x: centerX + CGFloat(cos(angle)) * replicaRadius,
                y: centerY + CGFloat(sin(angle)) * replicaRadius
            )
            nodeItems.append(TopologyNodeItem(node: node, position: pos, color: AppColor.success))

            // Line to primary
            guard let replicaOf = node.replicaOf else { continue }
            guard let primary = primaries.first(where: { $0.endpoint == replicaOf }) else { continue }
            guard
                let primaryItem = nodeItems.first(
                    where: { $0.node.endpoint == primary.endpoint }
                )
            else {
                continue
            }
            lines.append(
                TopologyLine(
                    from: primaryItem.position,
                    to: pos,
                    color: AppColor.info.opacity(0.4)
                )
            )
        }

        return TopologyLayout(nodes: nodeItems, lines: lines)
    }
}

// MARK: - Layout Types

/// Press + hover feedback for topology nodes. Hover scales the node up
/// slightly so the small 44pt hit area reads as tappable.
private struct TopologyNodeButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : isHovering ? 1.06 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: isHovering)
            .animation(AppAnimation.quick, value: configuration.isPressed)
    }
}

private struct TopologyNodeItem: Identifiable {
    var id: String { node.id }
    let node: RedisClusterNodeSummary
    let position: CGPoint
    let color: Color
}

private struct TopologyLine: Identifiable {
    let id = UUID()
    let from: CGPoint
    let to: CGPoint
    let color: Color
}

private struct TopologyLayout {
    let nodes: [TopologyNodeItem]
    let lines: [TopologyLine]
}
