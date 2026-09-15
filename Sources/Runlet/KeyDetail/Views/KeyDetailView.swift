import SwiftUI

/// A production mutation staged behind a typed confirmation.
struct PendingProductionWrite: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmText: String
    let confirmButtonTitle: String
    let action: () -> Void
}

struct KeyDetailView: View {
    @Environment(TabState.self) var tab
    @State var didCopyKey = false
    @State var showingAddHashField = false
    @State var newHashField = ""
    @State var newHashValue = ""
    @State var showingAddListElement = false
    @State var newListElement = ""
    @State var newListInsertPosition: ListInsertPosition = .head
    @State var showingAddSetMember = false
    @State var newSetMember = ""
    @State var showingAddZSetMember = false
    @State var newZSetMember = ""
    @State var newZSetScore = ""
    @State var keyPendingDeletion: RedisKeyEntry?
    @State var showingTTLEditor = false
    @State var ttlInput = ""
    @State var ttlEditorError: String?
    @State var autoRefreshInterval: TimeInterval = 0
    @State var productionConfirmText = ""
    @State var pendingProductionWrite: PendingProductionWrite?
    @State var productionWriteConfirmText = ""
    @State var deleteFeedbackTrigger = false
    @State var ttlFeedbackTrigger = false

    let maxTTL = 2_147_483_647

    // MARK: - Body
    var body: some View {
        @Bindable var tab = tab

        VStack(spacing: 0) {
            if let key = tab.selectedKey {
                headerView(key: key)

                Divider()

                if let error = tab.keyDetailError {
                    ErrorBanner(message: error, dismissAction: { tab.keyDetailError = nil })
                    Divider()
                }

                if tab.isLoadingDetail {
                    Spacer()
                    LoadingState(message: "Loading value…")
                    Spacer()
                } else {
                    detailContent(key: key)
                }
            } else {
                Spacer()
                ContentUnavailableView(
                    "Select a key to view its value",
                    systemImage: "sidebar.left",
                    description: Text("Choose a key from the list on the left")
                )
                Spacer()
            }
        }
        .confirmationDialog(
            "Delete Key",
            isPresented: Binding(
                get: { keyPendingDeletion != nil && !isProduction },
                set: { isPresented in
                    if !isPresented {
                        keyPendingDeletion = nil
                    }
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
            Button("Cancel", role: .cancel) {
                keyPendingDeletion = nil
            }
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
        .sheet(item: $pendingProductionWrite) { pending in
            ProductionConfirmView(
                title: pending.title,
                message: pending.message,
                confirmText: pending.confirmText,
                confirmButtonTitle: pending.confirmButtonTitle,
                input: $productionWriteConfirmText,
                onConfirm: {
                    let action = pending.action
                    pendingProductionWrite = nil
                    productionWriteConfirmText = ""
                    action()
                },
                onCancel: {
                    pendingProductionWrite = nil
                    productionWriteConfirmText = ""
                }
            )
            .presentationSizing(.form)
        }
        .onChange(of: tab.selectedKey?.key) {
            showingTTLEditor = false
            ttlEditorError = nil
            pendingProductionWrite = nil
            productionWriteConfirmText = ""
        }
        .sensoryFeedback(.success, trigger: deleteFeedbackTrigger)
        .sensoryFeedback(.success, trigger: ttlFeedbackTrigger)
        .task(id: autoRefreshTaskID) {
            guard autoRefreshInterval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(autoRefreshInterval))
                guard !Task.isCancelled, tab.selectedKey != nil, !tab.isLoadingDetail else { continue }
                await tab.refreshSelectedKey()
            }
        }
    }

    var autoRefreshTaskID: String {
        "\(tab.selectedKey?.key ?? "")|\(autoRefreshInterval)"
    }

    var isProduction: Bool {
        tab.selectedConnection?.environment == .production
    }

    /// Runs a mutation immediately, or stages it behind a typed confirmation
    /// on production. Deletes already confirm; this covers adds/overwrites/TTL.
    func guardProductionWrite(
        title: String,
        message: String,
        confirmText: String,
        confirmButtonTitle: String,
        action: @escaping () -> Void
    ) {
        if isProduction {
            pendingProductionWrite = PendingProductionWrite(
                title: title,
                message: message,
                confirmText: confirmText,
                confirmButtonTitle: confirmButtonTitle,
                action: action
            )
        } else {
            action()
        }
    }
}

// MARK: - TTL Editor Popover
struct KeyTTLEditorPopover: View {
    let keyName: String
    @Binding var ttlInput: String
    let error: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text(keyName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: AppSpacing.small) {
                Text("TTL")
                    .font(.headline)
                TextField("No limit", text: $ttlInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: AppSize.ttlInputWidth)
                    .focused($inputFocused)
                    .onSubmit(onSave)
                Text("s")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Empty means the key never expires.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(AppColor.error)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppSpacing.large)
        .frame(width: AppSize.ttlEditorWidth)
        .onAppear { inputFocused = true }
    }
}
