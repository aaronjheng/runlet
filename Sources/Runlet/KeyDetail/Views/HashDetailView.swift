import SwiftUI

// MARK: - Hash Detail View

struct HashEntry: Identifiable {
    var id: String { field }
    let field: String
    let value: String
}

struct HashDetailView: View {
    let key: String
    let rows: [(String, String)]
    let totalCount: Int?
    let searchText: String
    let hasMoreRows: Bool
    var isProduction: Bool = false
    let onSearch: (String) -> Void
    let onLoadMore: () -> Void
    let onAddField: () -> Void
    let onSaveField: (String, String) -> Void
    let onDeleteField: (String) -> Void

    @State private var editingField: String?
    @State private var editValue = ""
    @State private var pendingSearchText = ""
    @State private var fieldPendingDeletion: String?
    @State private var productionConfirmText = ""
    @State private var selection = Set<String>()

    private var hashEntries: [HashEntry] {
        rows.map { HashEntry(field: $0.0, value: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterField("Field filter", text: $pendingSearchText) {
                onSearch(pendingSearchText)
            }
            .padding(AppSpacing.small)

            Divider()

            Table(hashEntries, selection: $selection) {
                TableColumn("Field") { row in
                    Text(row.field)
                        .font(AppFont.dataCell)
                        .lineLimit(2)
                        .copyableCell(row.field, row: "\(row.field)\t\(row.value)")
                }
                .width(min: 100, ideal: 150, max: 300)

                TableColumn("Value") { row in
                    EditableHashCell(
                        row: row,
                        editingField: $editingField,
                        editValue: $editValue,
                        rowValue: "\(row.field)\t\(row.value)",
                        onSaveField: onSaveField
                    )
                }

                TableColumn("Actions") { row in
                    HStack(spacing: AppSpacing.small) {
                        Button("Edit Field", systemImage: "square.and.pencil") {
                            editingField = row.field
                            editValue = row.value
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(IconButtonStyle(size: .row, weight: .semibold))
                        .help("Edit field")

                        DeleteIconButton(
                            action: { fieldPendingDeletion = row.field },
                            helpText: "Delete field",
                            size: .row
                        )
                    }
                }
                .width(AppSize.tableActionsWidthDouble)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let field = ids.first {
                    if let value = hashEntries.first(where: { $0.field == field })?.value {
                        Button("Copy Field") {
                            copyToPasteboard(field)
                        }
                        Button("Copy Row") {
                            copyToPasteboard("\(field)\t\(value)")
                        }
                        Divider()
                        Button("Edit Field") {
                            editingField = field
                            editValue = value
                        }
                        Button("Delete Field", role: .destructive) {
                            fieldPendingDeletion = field
                        }
                    }
                }
            }
            .overlay {
                if hashEntries.isEmpty {
                    VStack {
                        Spacer()
                        ContentUnavailableView(
                            searchText.isEmpty ? "No fields" : "No matching fields",
                            systemImage: searchText.isEmpty ? "tablecells" : "magnifyingglass",
                            description: Text(
                                searchText.isEmpty ? "This hash holds no fields" : "Try a different filter")
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
                    countText: detailCountText(loaded: rows.count, total: totalCount, noun: "fields")
                )

                if hasMoreRows {
                    Button("Load More") {
                        onLoadMore()
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button("Add Field", systemImage: "plus") {
                    onAddField()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Add Field")
            }
        }
        .onAppear {
            pendingSearchText = searchText
        }
        .onChange(of: searchText) { _, newValue in
            pendingSearchText = newValue
        }
        .confirmationDialog(
            "Delete Field",
            isPresented: Binding(
                get: { fieldPendingDeletion != nil && !isProduction },
                set: { if !$0 { fieldPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let field = fieldPendingDeletion {
                Button("Delete", role: .destructive) {
                    onDeleteField(field)
                    fieldPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let field = fieldPendingDeletion {
                Text("This permanently deletes field \"\(field)\" from \"\(key)\".")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { fieldPendingDeletion != nil && isProduction },
                set: {
                    if !$0 {
                        fieldPendingDeletion = nil
                        productionConfirmText = ""
                    }
                }
            )
        ) {
            if let field = fieldPendingDeletion {
                ProductionConfirmView(
                    title: "Delete Field",
                    message: "This permanently deletes field \"\(field)\" from \"\(key)\".",
                    confirmText: "DELETE",
                    confirmButtonTitle: "Delete",
                    input: $productionConfirmText,
                    onConfirm: {
                        onDeleteField(field)
                        fieldPendingDeletion = nil
                        productionConfirmText = ""
                    },
                    onCancel: {
                        fieldPendingDeletion = nil
                        productionConfirmText = ""
                    }
                )
                .presentationSizing(.form)
            }
        }
    }
}

struct EditableHashCell: View {
    let row: HashEntry
    @Binding var editingField: String?
    @Binding var editValue: String
    let rowValue: String
    let onSaveField: (String, String) -> Void

    var body: some View {
        if editingField == row.field {
            InlineTextField(
                text: $editValue,
                onSubmit: { onSaveField(row.field, editValue) },
                onCancel: { editingField = nil }
            )
        } else {
            Text(row.value)
                .font(AppFont.dataCell)
                .lineLimit(2)
                .copyableCell(row.value, row: rowValue)
                .help("Double-click to edit")
                .onTapGesture(count: 2) {
                    editingField = row.field
                    editValue = row.value
                }
        }
    }
}
