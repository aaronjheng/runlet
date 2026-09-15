import SwiftUI

// MARK: - Set Detail View

struct SetEntry: Identifiable {
    var id: String { member }
    let member: String
}

struct SetDetailView: View {
    let key: String
    let rows: [(String, String)]
    let totalCount: Int?
    let searchText: String
    let hasMoreRows: Bool
    var isProduction: Bool = false
    let onSearch: (String) -> Void
    let onLoadMore: () -> Void
    let onAddMember: () -> Void
    let onDeleteMember: (String) -> Void

    @State private var pendingSearchText = ""
    @State private var memberPendingDeletion: String?
    @State private var productionConfirmText = ""
    @State private var selection = Set<String>()

    private var setEntries: [SetEntry] {
        rows.map { SetEntry(member: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterField("Member filter", text: $pendingSearchText) {
                onSearch(pendingSearchText)
            }
            .padding(AppSpacing.small)

            Divider()

            Table(setEntries, selection: $selection) {
                TableColumn("Member") { row in
                    Text(row.member)
                        .font(AppFont.dataCell)
                        .lineLimit(2)
                        .copyableCell(row.member, row: row.member)
                }

                TableColumn("Actions") { row in
                    DeleteIconButton(
                        action: { memberPendingDeletion = row.member },
                        helpText: "Delete member",
                        size: .row
                    )
                }
                .width(AppSize.tableActionsWidthSingle)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let member = ids.first {
                    Button("Copy Member") {
                        copyToPasteboard(member)
                    }
                    Button("Copy Row") {
                        copyToPasteboard(member)
                    }
                    Divider()
                    Button("Delete Member", role: .destructive) {
                        memberPendingDeletion = member
                    }
                }
            }
            .overlay {
                if setEntries.isEmpty {
                    VStack {
                        Spacer()
                        ContentUnavailableView(
                            searchText.isEmpty ? "No members" : "No matching members",
                            systemImage: searchText.isEmpty ? "circle.grid.cross" : "magnifyingglass",
                            description: Text(
                                searchText.isEmpty ? "This set holds no members" : "Try a different filter")
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
