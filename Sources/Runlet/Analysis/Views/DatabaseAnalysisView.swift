import SwiftUI
import UniformTypeIdentifiers

// MARK: - Database Analysis View

struct DatabaseAnalysisView: View {
    @Environment(TabState.self) private var tab
    @State private var showingProductionWarning = false
    @State private var isExporting = false
    @State private var exportReport: AnalysisReportDocument?

    private var isProduction: Bool {
        tab.selectedConnection?.environment == .production
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: AppSpacing.medium) {
                Spacer()

                if tab.isLoadingAnalysis {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    if isProduction {
                        showingProductionWarning = true
                    } else {
                        Task { await tab.runDatabaseAnalysis() }
                    }
                } label: {
                    Label(
                        tab.analysis == nil ? "Run Analysis" : "Refresh",
                        systemImage: tab.analysis == nil ? "play.fill" : "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(tab.isLoadingAnalysis)
                .alert("Run Analysis on Production?", isPresented: $showingProductionWarning) {
                    Button("Cancel", role: .cancel) {}
                    Button("Run Analysis") {
                        Task { await tab.runDatabaseAnalysis() }
                    }
                } message: {
                    Text(
                        "Analysis will scan up to 2,000 keys and send TYPE, "
                            + "MEMORY USAGE, and TTL for each. This can be "
                            + "resource-intensive on a production server.")
                }

                Button {
                    exportAnalysis()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(tab.analysis == nil)
            }
            .panelToolbar(horizontalPadding: AppSpacing.small)

            Divider()

            if let error = tab.analysisError {
                ErrorBanner(message: error, dismissAction: { tab.analysisError = nil })
                Divider()
            }

            if tab.isLoadingAnalysis {
                Spacer()
                LoadingState(message: "Analyzing database…")
                Spacer()
            } else if let analysis = tab.analysis {
                analysisContent(analysis)
            } else {
                Spacer()
                ContentUnavailableView(
                    "No analysis data",
                    systemImage: "chart.pie",
                    description: Text("Run Analysis to see database statistics")
                )
                Button("Run Analysis") {
                    if isProduction {
                        showingProductionWarning = true
                    } else {
                        Task { await tab.runDatabaseAnalysis() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, AppSpacing.small)
                Spacer()
            }
            Divider()
            PanelFooterBar {
                if let analysis = tab.analysis {
                    StatusFooterView(
                        countText: "\(analysis.totalKeys) keys",
                        sizeText: analysis.serverMetrics.usedMemoryHuman
                    )
                } else if tab.isLoadingAnalysis {
                    Label("Analyzing…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                } else if tab.analysisError != nil {
                    Label("Analysis failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppColor.error)
                } else {
                    Text("No analysis data")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .onDisappear {
            tab.cancelAnalysis()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportReport,
            contentType: .plainText,
            defaultFilename: exportReport?.defaultFilename
        ) { _ in }
    }

    @ViewBuilder
    private func analysisContent(_ analysis: DatabaseAnalysis) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Summary bar
                summaryBar(analysis)
                Divider()

                VStack(spacing: AppSpacing.small) {
                    // Type Distribution
                    typeDistributionSection(analysis)
                    // Top Keys
                    topKeysSection(analysis)
                }
                .padding([.horizontal, .top], AppSpacing.large)

                // Expiration Timeline
                expirationSection(analysis)
                    .padding(.horizontal, AppSpacing.large)
                    .padding(.bottom, AppSpacing.small)
            }
        }
    }

    private func summaryBar(_ analysis: DatabaseAnalysis) -> some View {
        HStack(spacing: AppSpacing.large) {
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                Text("Last analyzed:")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 0) {
                    Text(analysis.analyzedAt, style: .time)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(" (\(analysis.keysSampled) keys)")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Rectangle()
                .fill(.separator)
                .frame(width: 1)

            AnalysisStatView(label: "Total Keys", value: "\(analysis.totalKeys)")
            AnalysisStatView(label: "Total Memory", value: analysis.serverMetrics.usedMemoryHuman)
            AnalysisStatView(label: "Hit Rate", value: String(format: "%.1f%%", analysis.serverMetrics.hitRate))
            AnalysisStatView(label: "Ops/sec", value: "\(analysis.serverMetrics.opsPerSecond)")
            AnalysisStatView(label: "Clients", value: "\(analysis.serverMetrics.connectedClients)")

            if analysis.isEstimate {
                Badge(
                    text: "Estimate",
                    foregroundColor: AppColor.warning,
                    backgroundColor: AppColor.badgeBackground(AppColor.warning)
                )
                .help("Totals are estimated from a key sample, not a full scan")
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.small)
    }

    private func typeDistributionSection(_ analysis: DatabaseAnalysis) -> some View {
        Card(title: "Type Distribution") {
            let types = analysis.typeDistribution.keys.sorted()
            if types.isEmpty {
                Text("No data")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: AppSpacing.xSmall) {
                    HStack {
                        Text("Type").font(.body).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text("Count").font(.body).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        Text("Memory").font(.body).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                        Text("Avg Bytes").font(.body).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                    }
                    ForEach(types, id: \.self) { type in
                        if let stats = analysis.typeDistribution[type] {
                            HStack {
                                Text(redisKeyTypeTitle(type))
                                    .font(.body)
                                    .frame(width: 60, alignment: .leading)
                                Text("\(stats.count)")
                                    .font(AppFont.dataCell)
                                    .frame(width: 70, alignment: .trailing)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(stats.memory), countStyle: .file))
                                    .font(AppFont.dataCell)
                                    .frame(width: 120, alignment: .trailing)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(stats.avgSize), countStyle: .file))
                                    .font(AppFont.dataCell)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(AppSpacing.small)
                .background(AppColor.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
            }
        }
    }

    private func topKeysSection(_ analysis: DatabaseAnalysis) -> some View {
        Card(title: "Top Keys by Memory") {
            if analysis.topKeysByMemory.isEmpty {
                Text("No data")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Grid(horizontalSpacing: AppSpacing.small, verticalSpacing: AppSpacing.xxSmall) {
                    ForEach(analysis.topKeysByMemory.prefix(10)) { entry in
                        GridRow {
                            Text(entry.key)
                                .font(.body)
                                .lineLimit(1)
                                .gridColumnAlignment(.leading)
                            Text(entry.memoryText)
                                .font(AppFont.dataCell)
                                .foregroundStyle(.secondary)
                                .frame(width: AppSize.formFieldWidth, alignment: .trailing)
                        }
                    }
                }
                .padding(AppSpacing.small)
                .background(AppColor.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
            }
        }
    }

    private func expirationSection(_ analysis: DatabaseAnalysis) -> some View {
        Card(title: "Expiration Timeline") {
            if analysis.expirationSummary.isEmpty {
                Text("No data")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                let maxCount = analysis.expirationSummary.map(\.keyCount).max() ?? 1
                VStack(spacing: AppSpacing.mini) {
                    ForEach(analysis.expirationSummary) { bucket in
                        HStack(spacing: AppSpacing.small) {
                            Text(bucket.label)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .leading)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                        .fill(AppColor.trackBackground)
                                        .frame(height: AppSize.barHeight)
                                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                        .fill(expirationColor(bucket.label))
                                        .frame(
                                            width: max(
                                                AppSize.barMinWidth,
                                                geo.size.width * CGFloat(bucket.keyCount) / CGFloat(maxCount)
                                            ),
                                            height: AppSize.barHeight
                                        )
                                }
                            }
                            .frame(height: AppSize.barHeight)

                            Text("\(bucket.keyCount)")
                                .font(AppFont.dataCell)
                                .frame(width: 50, alignment: .trailing)
                            Text(bucket.memoryText)
                                .font(AppFont.dataCell)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
                .padding(AppSpacing.small)
                .background(AppColor.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
            }
        }
    }

    private func typeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "string": return "doc.text"
        case "list": return "list.bullet"
        case "hash": return "tablecells"
        case "set": return "circle.grid.cross"
        case "zset": return "arrow.up.arrow.down.circle"
        default: return "questionmark.circle"
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "string": return AppColor.chartString
        case "list": return AppColor.chartList
        case "hash": return AppColor.chartHash
        case "set": return AppColor.chartSet
        case "zset": return AppColor.chartZSet
        case "stream": return .secondary
        default: return .secondary
        }
    }

    private func expirationColor(_ label: String) -> Color {
        switch label {
        case "< 1h": return AppColor.ttlExpired
        case "1-6h": return AppColor.ttlShort
        case "6-24h": return AppColor.ttlMedium
        case "1-7d": return AppColor.ttlLong
        case "7-30d": return AppColor.ttlDistant
        case "> 30d": return .secondary
        case "No expiry": return .gray
        default: return .secondary
        }
    }

    private func exportAnalysis() {
        guard let analysis = tab.analysis else { return }
        var lines: [String] = [
            "Database Analysis - \(DateFormatter.localizedString(from: analysis.analyzedAt, dateStyle: .medium, timeStyle: .medium))",
            "Keys Sampled: \(analysis.keysSampled)\(analysis.isEstimate ? " (estimate)" : "")",
            "Total Keys: \(analysis.totalKeys)",
            "Total Memory: \(analysis.serverMetrics.usedMemoryHuman)",
            "Hit Rate: \(String(format: "%.1f%%", analysis.serverMetrics.hitRate))",
            "Ops/sec: \(analysis.serverMetrics.opsPerSecond)",
            "Clients: \(analysis.serverMetrics.connectedClients)",
            "",
            "Type Distribution:",
        ]
        for (type, stats) in analysis.typeDistribution.sorted(by: { $0.value.count > $1.value.count }) {
            let memStr = ByteCountFormatter.string(fromByteCount: Int64(stats.memory), countStyle: .file)
            lines.append("  \(type): \(stats.count) keys, \(memStr)")
        }
        lines.append("")
        lines.append("Top Keys by Memory:")
        for entry in analysis.topKeysByMemory.prefix(20) {
            lines.append("  \(entry.key) (\(entry.type)) - \(entry.memoryText)")
        }
        lines.append("")
        lines.append("Expiration Timeline:")
        for bucket in analysis.expirationSummary {
            lines.append("  \(bucket.label): \(bucket.keyCount) keys, \(bucket.memoryText)")
        }

        exportReport = AnalysisReportDocument(
            text: lines.joined(separator: "\n"),
            defaultFilename: "analysis-\(ISO8601DateFormatter().string(from: analysis.analyzedAt)).txt"
        )
        isExporting = true
    }
}

// MARK: - Analysis Report Document

/// Plain-text wrapper for `fileExporter`, carrying the timestamped
/// suggested filename shown in the save dialog.
private struct AnalysisReportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    static let writableContentTypes: [UTType] = [.plainText]

    let text: String
    let defaultFilename: String

    init(text: String, defaultFilename: String) {
        self.text = text
        self.defaultFilename = defaultFilename
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(data: data, encoding: .utf8) ?? ""
        defaultFilename = "analysis.txt"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Stat Item

struct AnalysisStatView: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppFont.dataCell)
                .foregroundStyle(.primary)
        }
    }
}
