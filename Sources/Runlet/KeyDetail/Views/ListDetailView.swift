import SwiftUI

// MARK: - List Detail View

struct ListEntry: Identifiable {
    var id: Int { index }
    let index: Int
    let value: String
}

struct EditableListCell: View {
    let row: ListEntry
    @Binding var editingIndex: Int?
    @Binding var editValue: String
    let rowValue: String
    let onSaveElement: (Int, String) -> Void

    private var isEditing: Bool { editingIndex == row.index }

    var body: some View {
        Text(row.value)
            .font(AppFont.dataCell)
            .lineLimit(2)
            .selectionForeground()
            // The editor covers this cell while it is open; keeping the text in
            // place underneath holds the row at its displayed height.
            .opacity(isEditing ? 0 : 1)
            .copyableCell(row.value, row: rowValue)
            .help("Double-click to edit")
            .overlay {
                if isEditing {
                    InlineTextField(
                        original: row.value,
                        text: $editValue,
                        onSubmit: { onSaveElement(row.index, editValue) },
                        onCancel: { editingIndex = nil }
                    )
                }
            }
    }
}

struct ListDetailView: View {
    let key: String
    let rows: [(String, String)]
    let totalCount: Int?
    let order: KeyDetailOrder
    let hasMoreRows: Bool
    var isProduction: Bool = false
    let onLoadMore: () -> Void
    let onOrderChange: (KeyDetailOrder) -> Void
    let onAddElement: () -> Void
    let onSaveElement: (Int, String) -> Void
    let onDeleteElement: (Int, String) -> Void

    @State private var editingIndex: Int?
    @State private var editValue = ""
    @State private var elementPendingDeletion: ListEntry?
    @State private var productionConfirmText = ""
    @State private var selection = Set<Int>()

    private var listEntries: [ListEntry] {
        rows.compactMap { row in
            guard let index = Int(row.0) else { return nil }
            return ListEntry(index: index, value: row.1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FullWidthTable(
                rows: listEntries,
                columns: [
                    FullWidthTable.Column(
                        title: "Index",
                        width: 60,
                        resizable: false,
                        sort: FullWidthTable.Column.Sort(
                            ascending: order == .ascending,
                            help: "Sort by index"
                        ) {
                            onOrderChange(order == .ascending ? .descending : .ascending)
                        }
                    ) { row in
                        AnyView(
                            Text("\(row.index)")
                                .font(AppFont.monoSubheadline)
                                .selectionForeground(secondary: true)
                                .copyableCell("\(row.index)", row: "\(row.index)\t\(row.value)")
                        )
                    },
                    FullWidthTable.Column(title: "Value") { row in
                        AnyView(
                            EditableListCell(
                                row: row,
                                editingIndex: $editingIndex,
                                editValue: $editValue,
                                rowValue: "\(row.index)\t\(row.value)",
                                onSaveElement: onSaveElement
                            )
                        )
                    },
                    FullWidthTable.Column(
                        title: "Actions",
                        width: AppSize.tableActionsWidthDouble,
                        resizable: false
                    ) { row in
                        AnyView(
                            HStack(spacing: AppSpacing.small) {
                                Button("Edit Element", systemImage: "square.and.pencil") {
                                    editingIndex = row.index
                                    editValue = row.value
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(IconButtonStyle(size: .tableAction, weight: .semibold))
                                .help("Edit element")

                                DeleteIconButton(
                                    action: { elementPendingDeletion = row },
                                    helpText: "Delete element",
                                    size: .tableAction
                                )
                            }
                        )
                    },
                ],
                selection: $selection,
                onDoubleClick: { row, column in
                    guard column == 1 else { return }
                    editingIndex = row.index
                    editValue = row.value
                },
                contextMenu: { row in
                    let menu = NSMenu()
                    menu.addItem(NSMenuItem("Copy Value") { copyToPasteboard(row.value) })
                    menu.addItem(
                        NSMenuItem("Copy Row") { copyToPasteboard("\(row.index)\t\(row.value)") }
                    )
                    menu.addItem(.separator())
                    menu.addItem(
                        NSMenuItem("Edit Element") {
                            editingIndex = row.index
                            editValue = row.value
                        }
                    )
                    menu.addItem(
                        NSMenuItem("Delete Element") { elementPendingDeletion = row }
                    )
                    return menu
                }
            )
            .overlay {
                if listEntries.isEmpty {
                    VStack {
                        Spacer()
                        ContentUnavailableView(
                            "No elements",
                            systemImage: "list.bullet",
                            description: Text("This list holds no elements")
                        )
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }
            }

            Divider()

            PanelFooterBar {
                StatusFooterView(
                    countText: detailCountText(loaded: rows.count, total: totalCount, noun: "elements")
                )

                if hasMoreRows {
                    Button("Load More") {
                        onLoadMore()
                    }
                    .buttonStyle(.borderless)
                    .hoverBackground()
                }

                Spacer()

                Button("Add Element", systemImage: "plus") {
                    onAddElement()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Add element")
            }
        }
        .confirmationDialog(
            "Delete Element",
            isPresented: Binding(
                get: { elementPendingDeletion != nil && !isProduction },
                set: { if !$0 { elementPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let row = elementPendingDeletion {
                Button("Delete", role: .destructive) {
                    onDeleteElement(row.index, row.value)
                    elementPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let row = elementPendingDeletion {
                Text("This permanently deletes element at index \(row.index) from \"\(key)\".")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { elementPendingDeletion != nil && isProduction },
                set: {
                    if !$0 {
                        elementPendingDeletion = nil
                        productionConfirmText = ""
                    }
                }
            )
        ) {
            if let row = elementPendingDeletion {
                ProductionConfirmView(
                    title: "Delete Element",
                    message: "This permanently deletes element at index \(row.index) from \"\(key)\".",
                    confirmText: "DELETE",
                    confirmButtonTitle: "Delete",
                    input: $productionConfirmText,
                    onConfirm: {
                        onDeleteElement(row.index, row.value)
                        elementPendingDeletion = nil
                        productionConfirmText = ""
                    },
                    onCancel: {
                        elementPendingDeletion = nil
                        productionConfirmText = ""
                    }
                )
                .presentationSizing(.form)
            }
        }
    }
}
