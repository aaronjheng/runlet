import SwiftUI

// MARK: - ZSet Detail View

struct ZSetEntry: Identifiable {
    var id: String { member }
    let score: String
    let member: String
}

struct ZSetDetailView: View {
    let key: String
    let rows: [(String, String)]
    let totalCount: Int?
    let searchText: String
    let order: KeyDetailOrder
    let hasMoreRows: Bool
    var isProduction: Bool = false
    let onSearch: (String) -> Void
    let onOrderChange: (KeyDetailOrder) -> Void
    let onLoadMore: () -> Void
    let onAddMember: () -> Void
    let onSaveMember: (String, String) -> Void
    let onDeleteMember: (String) -> Void

    @State private var editingMember: String?
    @State private var editScore = ""
    @State private var pendingSearchText = ""
    @State private var memberPendingDeletion: String?
    @State private var productionConfirmText = ""
    @State private var selection = Set<String>()

    private var zsetEntries: [ZSetEntry] {
        rows.map { ZSetEntry(score: $0.0, member: $0.1) }
    }

    /// Score column header sort control. 125pt = 10pt leading inset + 100pt
    /// column + 15pt intercell gap.
    private var scoreHeaderSortControl: some View {
        HeaderSortControl(
            ascending: order == .ascending,
            headerWidth: 125,
            disabled: !pendingSearchText.isEmpty,
            helpText: pendingSearchText.isEmpty ? "Sort by score" : "Sort order unavailable while filtering"
        ) {
            onOrderChange(order == .ascending ? .descending : .ascending)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterField("Member filter", text: $pendingSearchText) {
                onSearch(pendingSearchText)
            }
            .padding(AppSpacing.small)

            if !pendingSearchText.isEmpty {
                Text("Clear the filter to change the sort order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.bottom, AppSpacing.xxSmall)
            }

            Divider()

            Table(zsetEntries, selection: $selection) {
                TableColumn("Score") { row in
                    EditableZSetCell(
                        row: row,
                        editingMember: $editingMember,
                        editScore: $editScore,
                        rowValue: "\(row.score)\t\(row.member)",
                        onSaveMember: onSaveMember
                    )
                }
                .width(100)

                TableColumn("Member") { row in
                    Text(row.member)
                        .font(AppFont.dataCell)
                        .lineLimit(2)
                        .copyableCell(row.member, row: "\(row.score)\t\(row.member)")
                }

                TableColumn("Actions") { row in
                    HStack(spacing: AppSpacing.small) {
                        Button("Edit Score", systemImage: "square.and.pencil") {
                            editingMember = row.member
                            editScore = row.score
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(IconButtonStyle(size: .row, weight: .semibold))
                        .help("Edit score")

                        DeleteIconButton(
                            action: { memberPendingDeletion = row.member },
                            helpText: "Delete member",
                            size: .row
                        )
                    }
                }
                .width(AppSize.tableActionsWidthDouble)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let member = ids.first {
                    if let score = zsetEntries.first(where: { $0.member == member })?.score {
                        Button("Copy Member") {
                            copyToPasteboard(member)
                        }
                        Button("Copy Row") {
                            copyToPasteboard("\(score)\t\(member)")
                        }
                        Divider()
                        Button("Edit Score") {
                            editingMember = member
                            editScore = score
                        }
                        Button("Delete Member", role: .destructive) {
                            memberPendingDeletion = member
                        }
                    }
                }
            }
            .overlay {
                if zsetEntries.isEmpty {
                    VStack {
                        Spacer()
                        ContentUnavailableView(
                            searchText.isEmpty ? "No members" : "No matching members",
                            systemImage: searchText.isEmpty
                                ? "arrow.up.arrow.down.circle" : "magnifyingglass",
                            description: Text(
                                searchText.isEmpty ? "This sorted set holds no members" : "Try a different filter")
                        )
                        if !searchText.isEmpty {
                            Button("Clear Filter") {
                                pendingSearchText = ""
                                onSearch("")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.top, AppSpacing.small)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }
            }
            .overlay(alignment: .topLeading) {
                scoreHeaderSortControl
            }

            Divider()

            PanelFooterBar {
                StatusFooterView(
                    countText: detailCountText(loaded: rows.count, total: totalCount, noun: "members")
                )

                if hasMoreRows {
                    Button("Load More") {
                        onLoadMore()
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button("Add Member", systemImage: "plus") {
                    onAddMember()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Add member")
            }
        }
        .onAppear {
            pendingSearchText = searchText
        }
        .onChange(of: searchText) { _, newValue in
            pendingSearchText = newValue
        }
        .confirmationDialog(
            "Delete Member",
            isPresented: Binding(
                get: { memberPendingDeletion != nil && !isProduction },
                set: { if !$0 { memberPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let member = memberPendingDeletion {
                Button("Delete", role: .destructive) {
                    onDeleteMember(member)
                    memberPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let member = memberPendingDeletion {
                Text("This permanently deletes member \"\(member)\" from \"\(key)\".")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { memberPendingDeletion != nil && isProduction },
                set: {
                    if !$0 {
                        memberPendingDeletion = nil
                        productionConfirmText = ""
                    }
                }
            )
        ) {
            if let member = memberPendingDeletion {
                ProductionConfirmView(
                    title: "Delete Member",
                    message: "This permanently deletes member \"\(member)\" from \"\(key)\".",
                    confirmText: "DELETE",
                    confirmButtonTitle: "Delete",
                    input: $productionConfirmText,
                    onConfirm: {
                        onDeleteMember(member)
                        memberPendingDeletion = nil
                        productionConfirmText = ""
                    },
                    onCancel: {
                        memberPendingDeletion = nil
                        productionConfirmText = ""
                    }
                )
                .presentationSizing(.form)
            }
        }
    }
}

struct EditableZSetCell: View {
    let row: ZSetEntry
    @Binding var editingMember: String?
    @Binding var editScore: String
    let rowValue: String
    let onSaveMember: (String, String) -> Void

    var body: some View {
        if editingMember == row.member {
            InlineTextField(
                text: $editScore,
                onSubmit: { onSaveMember(row.member, editScore) },
                onCancel: { editingMember = nil }
            )
        } else {
            Text(row.score)
                .font(AppFont.dataCell)
                .lineLimit(1)
                .copyableCell(row.score, row: rowValue)
                .help("Double-click to edit")
                .onTapGesture(count: 2) {
                    editingMember = row.member
                    editScore = row.score
                }
        }
    }
}
