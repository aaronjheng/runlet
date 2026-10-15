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
    let onDeleteMembers: ([String]) -> Void
    /// Scroll-triggered incremental paging hook from `FullWidthTable`.
    var autoLoadMore: (() -> Void)?

    @State private var pendingSearchText = ""
    @State private var memberPendingDeletion: String?
    @State private var productionConfirmText = ""
    @State private var selection = Set<String>()
    @State private var memberViewer: MemberValueContext?
    @State private var bulkDeleteArmed = false

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

            FullWidthTable(
                rows: setEntries,
                columns: [
                    FullWidthTable.Column(title: "Member") { row in
                        AnyView(
                            Text(row.member)
                                .font(AppFont.dataCell)
                                .lineLimit(2)
                                .selectionForeground()
                                .copyableCell(row.member, row: row.member)
                        )
                    },
                    FullWidthTable.Column(
                        title: "Actions",
                        width: AppSize.tableActionsWidthDouble,
                        resizable: false
                    ) { row in
                        AnyView(
                            HStack(spacing: AppSpacing.small) {
                                Button("View Value", systemImage: "eye") {
                                    memberViewer = MemberValueContext(
                                        label: "Member: \(row.member)",
                                        value: row.member,
                                        onEdit: nil
                                    )
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(IconButtonStyle(size: .tableAction))
                                .help("View full value")

                                DeleteIconButton(
                                    action: { memberPendingDeletion = row.member },
                                    helpText: "Delete member",
                                    size: .tableAction
                                )
                            }
                        )
                    },
                ],
                selection: $selection,
                contextMenu: { row in
                    let menu = NSMenu()
                    menu.addItem(
                        NSMenuItem("View Value") {
                            memberViewer = MemberValueContext(
                                label: "Member: \(row.member)",
                                value: row.member,
                                onEdit: nil
                            )
                        }
                    )
                    menu.addItem(NSMenuItem("Copy Member") { copyToPasteboard(row.member) })
                    menu.addItem(NSMenuItem("Copy Row") { copyToPasteboard(row.member) })
                    menu.addItem(.separator())
                    menu.addItem(
                        NSMenuItem("Delete Member") { memberPendingDeletion = row.member }
                    )
                    return menu
                },
                onNearBottom: autoLoadMore
            )
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
                    .background(AppColor.secondaryBackground)
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
                    .hoverBackground()
                }

                if !selection.isEmpty {
                    Button {
                        bulkDeleteArmed = true
                    } label: {
                        Label("Delete \(selection.count) selected", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .hoverBackground()
                    .foregroundStyle(AppColor.error)
                    .help("Delete the selected members")
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
        .bulkMemberDeleteConfirmation(
            isArmed: $bulkDeleteArmed,
            context: BulkMemberDeleteContext(
                isProduction: isProduction,
                count: selection.count,
                noun: "member",
                keyName: key,
                onConfirm: {
                    let members = Array(selection)
                    selection.removeAll()
                    onDeleteMembers(members)
                }
            )
        )
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
        .sheet(item: $memberViewer) { context in
            MemberValueViewerSheet(keyName: key, context: context)
        }
    }
}
