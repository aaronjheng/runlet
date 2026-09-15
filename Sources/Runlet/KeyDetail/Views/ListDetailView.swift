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

    var body: some View {
        if editingIndex == row.index {
            InlineTextField(
                text: $editValue,
                onSubmit: { onSaveElement(row.index, editValue) },
                onCancel: { editingIndex = nil }
            )
        } else {
            Text(row.value)
                .font(AppFont.dataCell)
                .lineLimit(2)
                .copyableCell(row.value, row: rowValue)
                .help("Double-click to edit")
                .onTapGesture(count: 2) {
                    editingIndex = row.index
                    editValue = row.value
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
            Table(listEntries, selection: $selection) {
                TableColumn("Index") { row in
                    Text("\(row.index)")
                        .font(AppFont.monoSubheadline)
                        .foregroundStyle(.secondary)
                        .copyableCell("\(row.index)", row: "\(row.index)\t\(row.value)")
                }
                .width(60)

                TableColumn("Value") { row in
                    EditableListCell(
                        row: row,
                        editingIndex: $editingIndex,
                        editValue: $editValue,
                        rowValue: "\(row.index)\t\(row.value)",
                        onSaveElement: onSaveElement
                    )
                }

                TableColumn("Actions") { row in
                    HStack(spacing: AppSpacing.small) {
                        Button("Edit Element", systemImage: "square.and.pencil") {
                            editingIndex = row.index
                            editValue = row.value
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(IconButtonStyle(size: .row, weight: .semibold))
                        .help("Edit element")

                        DeleteIconButton(
                            action: { elementPendingDeletion = row },
                            helpText: "Delete element",
                            size: .row
                        )
                    }
                }
                .width(AppSize.tableActionsWidthDouble)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                if ids.count == 1, let index = ids.first {
                    if let row = listEntries.first(where: { $0.index == index }) {
                        Button("Copy Value") {
                            copyToPasteboard(row.value)
                        }
                        Button("Copy Row") {
                            copyToPasteboard("\(row.index)\t\(row.value)")
                        }
                        Divider()
                        Button("Edit Element") {
                            editingIndex = row.index
                            editValue = row.value
                        }
                        Button("Delete Element", role: .destructive) {
                            elementPendingDeletion = row
                        }
                    }
                }
            }
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
            .overlay(alignment: .topLeading) {
                // 85pt = 60pt Index column + 25pt intercell gap, mirroring the
                // score sort control in `ZSetDetailView`.
                HeaderSortControl(
                    ascending: order == .ascending,
                    headerWidth: 85,
                    helpText: "Sort by index"
                ) {
                    onOrderChange(order == .ascending ? .descending : .ascending)
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
