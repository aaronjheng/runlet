import SwiftUI

// MARK: - Key Detail Header

/// Header bar, TTL editing flow, and generic fallback bodies for
/// `KeyDetailView`. Kept in an extension of the main view so the state
/// properties stay owned by `KeyDetailView.swift`.
extension KeyDetailView {
    func headerView(key: RedisKeyEntry) -> some View {
        HStack(spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                    Badge(text: redisKeyTypeTitle(key.type), isLoading: key.type.isEmpty)
                    Text(key.key)
                        .font(.title3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }

                HStack(spacing: AppSpacing.compact) {
                    if let totalCount = tab.keyDetailTotalCount ?? key.length {
                        HStack(spacing: AppSpacing.xxSmall) {
                            Image(systemName: "number")
                            Text("Length: \(totalCount)")
                        }
                        .foregroundStyle(.secondary)
                    }
                    if tab.keyDetailTruncated {
                        Label(
                            "Showing first \(tab.stringDetailTruncationLimit) bytes",
                            systemImage: "doc.badge.ellipsis"
                        )
                        .foregroundStyle(AppColor.warning)
                        .help("The full value is not loaded into memory")
                    }
                    if let size = tab.valueSize ?? key.size {
                        HStack(spacing: AppSpacing.xxSmall) {
                            Image(systemName: "memorychip")
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .memory))
                        }
                        .foregroundStyle(.secondary)
                    }
                    Button {
                        beginEditingTTL(for: key)
                    } label: {
                        HStack(spacing: AppSpacing.xxSmall) {
                            Image(systemName: "clock")
                            Text("TTL: \(key.ttlText)")
                            Image(systemName: "square.and.pencil")
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, AppSpacing.xSmall)
                        .padding(.vertical, AppSpacing.xxSmall)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(key.hasExpiry ? AppColor.warning : .secondary)
                    .hoverBackground()
                    .opacity(tab.isLoadingDetail ? 0.5 : 1)
                    .disabled(tab.isLoadingDetail)
                    .accessibilityLabel("Edit TTL, \(key.ttlText)")
                    .help("Edit TTL")
                    .popover(isPresented: $showingTTLEditor, arrowEdge: .bottom) {
                        KeyTTLEditorPopover(
                            keyName: key.key,
                            ttlInput: $ttlInput,
                            error: ttlEditorError,
                            onSave: { saveTTL(for: key) },
                            onCancel: cancelTTLEdit
                        )
                        .onChange(of: ttlInput) { _, newValue in
                            let validatedValue = validatedTTLInput(newValue)
                            if validatedValue != newValue {
                                ttlInput = validatedValue
                                ttlEditorError = "Maximum TTL is 2,147,483,647 seconds."
                            } else {
                                ttlEditorError = nil
                            }
                        }
                    }
                    if let refreshedAt = tab.keyDetailLastRefreshedAt {
                        HStack(spacing: AppSpacing.xxSmall) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text(refreshedAt, style: .time)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: AppSpacing.small) {
                RefreshControl(
                    autoRefreshInterval: $autoRefreshInterval,
                    isLoading: tab.isLoadingDetail,
                    intervals: AutoRefreshInterval.options
                ) {
                    Task { await tab.refreshSelectedKey() }
                }

                Button("Copy Key", systemImage: didCopyKey ? "checkmark" : "doc.on.doc") {
                    copyToPasteboard(key.key)
                    didCopyKey = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        didCopyKey = false
                    }
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(didCopyKey ? AppColor.success : .primary)
                .buttonStyle(IconButtonStyle())
                .toolbarCapsule()
                .disabled(tab.isLoadingDetail)
                .help("Copy key")

                Button("Delete Key", systemImage: "trash", role: .destructive) {
                    keyPendingDeletion = key
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle(isDestructive: true))
                .foregroundStyle(AppColor.error)
                .toolbarCapsule()
                .disabled(tab.isLoadingDetail)
                .help("Delete key")
            }
        }
        .padding(AppSpacing.small)
    }

    // MARK: - TTL Editing

    func beginEditingTTL(for key: RedisKeyEntry) {
        if let ttl = key.ttl, ttl > 0 {
            ttlInput = "\(ttl)"
        } else {
            ttlInput = ""
        }
        ttlEditorError = nil
        showingTTLEditor = true
    }

    func cancelTTLEdit() {
        ttlEditorError = nil
        showingTTLEditor = false
    }

    func saveTTL(for key: RedisKeyEntry) {
        let ttl = ttlInput.isEmpty ? -1 : Int(ttlInput)
        guard let ttl else {
            ttlEditorError = "Enter a valid TTL."
            return
        }

        showingTTLEditor = false
        ttlEditorError = nil
        let ttlMessage =
            ttl == -1
            ? "This will remove the expiry of \"\(key.key)\" on a production server. The key will persist."
            : "This will set the TTL of \"\(key.key)\" to \(ttl) seconds on a production server. This action cannot be undone."
        guardProductionWrite(
            title: "Change TTL?",
            message: ttlMessage,
            confirmText: "SET TTL",
            confirmButtonTitle: "Save"
        ) {
            Task {
                let previousError = tab.keyDetailError
                await tab.updateKeyTTL(key, ttl: ttl)
                // Only fire success feedback when the operation didn't set a new error.
                if tab.keyDetailError == previousError {
                    ttlFeedbackTrigger.toggle()
                }
            }
        }
    }

    func validatedTTLInput(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard let ttl = Int(digits) else {
            return digits
        }
        return min(ttl, maxTTL).description
    }

    // MARK: - Generic Views

    /// Header for the first column of the generic fallback table, used for key
    /// types without a dedicated detail view (e.g. streams).
    var genericKeyHeader: String {
        switch tab.keyType {
        case "hash": "Field"
        case "list": "Index"
        case "set": "Member"
        case "zset": "Score"
        case "stream": "ID"
        default: "Key"
        }
    }

    var genericRowsView: some View {
        List {
            Section {
                ForEach(Array(tab.keyDetailRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top) {
                        Text(row.0)
                            .font(AppFont.monoSubheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: AppSize.detailKeyColumnWidth, alignment: .leading)
                            .copyableCell(row.0, row: "\(row.0)\t\(row.1)")
                        Text(row.1)
                            .font(AppFont.dataCell)
                            .textSelection(.enabled)
                            .copyableCell(row.1, row: "\(row.0)\t\(row.1)")
                    }
                }
            } header: {
                HStack {
                    Text(genericKeyHeader)
                        .frame(width: AppSize.detailKeyColumnWidth, alignment: .leading)
                    Text("Value")
                    Spacer()
                }
                .font(.subheadline)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    var emptyValueView: some View {
        if tab.keyDetail.isEmpty {
            Spacer()
            ContentUnavailableView(
                "Empty value",
                systemImage: "doc.text",
                description: Text("This key holds no data")
            )
            Spacer()
        } else {
            ScrollView {
                Text(tab.keyDetail)
                    .font(AppFont.dataCell)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.large)
            }
        }
    }
}
