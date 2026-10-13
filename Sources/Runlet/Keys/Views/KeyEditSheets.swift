import SwiftUI

// MARK: - Edit Sheets

enum ListInsertPosition {
    case head, tail
}

// MARK: - Add Member Sheet Scaffold

/// Shared chrome for the small "add member" sheets: icon + title header,
/// label/field rows, and a footer with the validation hint and Add button.
/// Mirrors the Add Key sheet's style so all creation dialogs read the same.
private struct AddMemberSheetScaffold<Content: View>: View {
    let title: String
    let hint: String?
    let addEnabled: Bool
    let onAdd: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: AppSpacing.medium) {
            header
            content()
            footer
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.mini)
        .presentationSurface()
    }

    private var header: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Spacer()
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: .tableAction))
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .help("Close (Esc)")
        }
    }

    private var footer: some View {
        HStack(spacing: AppSpacing.small) {
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add") { onAdd() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!addEnabled)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Label + field row used inside `AddMemberSheetScaffold`.
@ViewBuilder
@MainActor
private func addMemberSheetRow<Content: View>(
    alignment: VerticalAlignment = .center,
    label: String,
    @ViewBuilder field: () -> Content
) -> some View {
    HStack(alignment: alignment, spacing: AppSpacing.medium) {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: AppSize.formLabelWidthCompact, alignment: .leading)
        field()
    }
}

/// Editable single-value rows shared by the Add Key and add-member sheets.
@ViewBuilder
@MainActor
private func editSheetValueRows(
    values: Binding<[String]>,
    heading: String,
    placeholder: @escaping (Int) -> String,
    addLabel: String
) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.small) {
        editSheetSectionHeader(
            title: "\(heading) (\(values.wrappedValue.count))",
            addLabel: addLabel
        ) {
            values.wrappedValue.append("")
        }
        ForEach(values.wrappedValue.indices, id: \.self) { index in
            HStack(spacing: AppSpacing.small) {
                OwnFocusField { rowFocused in
                    TextField(
                        placeholder(index),
                        text: Binding(
                            get: { values.wrappedValue[index] },
                            set: { values.wrappedValue[index] = $0 }
                        )
                    )
                    .font(AppFont.monoSubheadline)
                    .focused(rowFocused)
                }
                editSheetRemoveButton(disabled: values.wrappedValue.count <= 1) {
                    values.wrappedValue.remove(at: index)
                }
            }
        }
    }
}

/// Editable first/second pair rows shared by the Add Key and add-member sheets.
@ViewBuilder
@MainActor
private func editSheetPairRows(
    pairs: Binding<[(first: String, second: String)]>,
    heading: String,
    firstPlaceholder: String,
    secondPlaceholder: String,
    addLabel: String,
    firstWidth: CGFloat? = nil
) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.small) {
        editSheetSectionHeader(
            title: "\(heading) (\(pairs.wrappedValue.count))",
            addLabel: addLabel
        ) {
            pairs.wrappedValue.append(("", ""))
        }
        ForEach(pairs.wrappedValue.indices, id: \.self) { index in
            HStack(spacing: AppSpacing.small) {
                OwnFocusField { firstFocused in
                    TextField(
                        firstPlaceholder,
                        text: Binding(
                            get: { pairs.wrappedValue[index].first },
                            set: { pairs.wrappedValue[index].first = $0 }
                        )
                    )
                    .font(AppFont.monoSubheadline)
                    .focused(firstFocused)
                }
                .modifier(ConditionalWidth(width: firstWidth))
                OwnFocusField { secondFocused in
                    TextField(
                        secondPlaceholder,
                        text: Binding(
                            get: { pairs.wrappedValue[index].second },
                            set: { pairs.wrappedValue[index].second = $0 }
                        )
                    )
                    .font(AppFont.monoSubheadline)
                    .focused(secondFocused)
                }
                editSheetRemoveButton(disabled: pairs.wrappedValue.count <= 1) {
                    pairs.wrappedValue.remove(at: index)
                }
            }
        }
    }
}

@MainActor
private func editSheetSectionHeader(title: String, addLabel: String, action: @escaping () -> Void) -> some View {
    HStack {
        Text(title)
            .font(.subheadline.weight(.medium))
        Spacer()
        Button(action: action) {
            Label(addLabel, systemImage: "plus")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.tint)
        .hoverBackground()
        .help(addLabel)
    }
}

@MainActor
private func editSheetRemoveButton(disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "minus.circle")
    }
    .buttonStyle(IconButtonStyle(size: .row))
    .foregroundStyle(.secondary)
    .disabled(disabled)
    .help("Remove row")
}

struct AddHashFieldSheet: View {
    let key: String
    let onSave: ([(field: String, value: String)]) -> Void
    let onCancel: () -> Void

    @State private var pairs: [(first: String, second: String)] = [("", "")]

    private var validPairs: [(field: String, value: String)] {
        pairs.compactMap { pair in
            guard !pair.first.isEmpty, !pair.second.isEmpty else { return nil }
            return (field: pair.first, value: pair.second)
        }
    }

    var body: some View {
        AddMemberSheetScaffold(
            title: "Add Hash Fields",
            hint: validPairs.isEmpty ? "Add at least one field with a value." : nil,
            addEnabled: !validPairs.isEmpty,
            onAdd: { onSave(validPairs) },
            onCancel: onCancel,
            content: {
                editSheetPairRows(
                    pairs: $pairs,
                    heading: "Fields",
                    firstPlaceholder: "Field",
                    secondPlaceholder: "Value",
                    addLabel: "Add Field"
                )
            }
        )
    }
}

struct AddListElementSheet: View {
    let key: String
    let onSave: ([String], ListInsertPosition) -> Void
    let onCancel: () -> Void

    @State private var values: [String] = [""]
    @State private var position: ListInsertPosition = .head

    var body: some View {
        AddMemberSheetScaffold(
            title: "Add List Elements",
            hint: values.contains { !$0.isEmpty } ? nil : "Add at least one element.",
            addEnabled: values.contains { !$0.isEmpty },
            onAdd: { onSave(values.filter { !$0.isEmpty }, position) },
            onCancel: onCancel,
            content: {
                editSheetValueRows(
                    values: $values,
                    heading: "Elements",
                    placeholder: { "Element \($0 + 1)" },
                    addLabel: "Add Element"
                )
                addMemberSheetRow(label: "Position") {
                    OptionsPicker(
                        "Insert position",
                        selection: $position,
                        options: [ListInsertPosition.head, .tail],
                        label: { $0 == .head ? "Head (LPUSH)" : "Tail (RPUSH)" }
                    )
                    .frame(maxWidth: 200, alignment: .leading)
                }
            }
        )
    }
}

struct AddArrayElementSheet: View {
    let key: String
    let onSave: ([(index: Int?, value: String)]) -> Void
    let onCancel: () -> Void

    @State private var pairs: [(first: String, second: String)] = [("", "")]

    /// A row is valid when the value is non-empty and the index is empty
    /// (append) or numeric.
    private var validEntries: [(index: Int?, value: String)] {
        pairs.compactMap { pair in
            guard !pair.second.isEmpty else { return nil }
            if pair.first.isEmpty {
                return (index: nil, value: pair.second)
            }
            guard let index = Int(pair.first) else { return nil }
            return (index: index, value: pair.second)
        }
    }

    private var hint: String? {
        if validEntries.isEmpty {
            return "Add at least one element; empty index appends."
        }
        let hasInvalidIndex = pairs.contains { pair in
            !pair.second.isEmpty && !pair.first.isEmpty && Int(pair.first) == nil
        }
        return hasInvalidIndex ? "Index must be a number." : nil
    }

    var body: some View {
        AddMemberSheetScaffold(
            title: "Add Array Elements",
            hint: hint,
            addEnabled: !validEntries.isEmpty,
            onAdd: { onSave(validEntries) },
            onCancel: onCancel,
            content: {
                editSheetPairRows(
                    pairs: $pairs,
                    heading: "Elements",
                    firstPlaceholder: "Index",
                    secondPlaceholder: "Value",
                    addLabel: "Add Element",
                    firstWidth: AppSize.formFieldWidth
                )
            }
        )
    }
}

struct AddSetMemberSheet: View {
    let key: String
    let onSave: ([String]) -> Void
    let onCancel: () -> Void

    @State private var members: [String] = [""]

    var body: some View {
        AddMemberSheetScaffold(
            title: "Add Set Members",
            hint: members.contains { !$0.isEmpty } ? nil : "Add at least one member.",
            addEnabled: members.contains { !$0.isEmpty },
            onAdd: { onSave(members.filter { !$0.isEmpty }) },
            onCancel: onCancel,
            content: {
                editSheetValueRows(
                    values: $members,
                    heading: "Members",
                    placeholder: { "Member \($0 + 1)" },
                    addLabel: "Add Member"
                )
            }
        )
    }
}

struct AddZSetMemberSheet: View {
    let key: String
    let onSave: ([(score: String, member: String)]) -> Void
    let onCancel: () -> Void

    @State private var pairs: [(first: String, second: String)] = [("", "")]

    private var validMembers: [(score: String, member: String)] {
        pairs.compactMap { pair in
            guard !pair.first.isEmpty, !pair.second.isEmpty else { return nil }
            return (score: pair.first, member: pair.second)
        }
    }

    var body: some View {
        AddMemberSheetScaffold(
            title: "Add Sorted Set Members",
            hint: validMembers.isEmpty ? "Add at least one member with a score." : nil,
            addEnabled: !validMembers.isEmpty,
            onAdd: { onSave(validMembers) },
            onCancel: onCancel,
            content: {
                editSheetPairRows(
                    pairs: $pairs,
                    heading: "Members",
                    firstPlaceholder: "Score",
                    secondPlaceholder: "Member",
                    addLabel: "Add Member",
                    firstWidth: AppSize.formFieldWidth
                )
            }
        )
    }
}

struct AddKeySheet: View {
    @Binding var keyName: String
    @Binding var keyType: String
    @Binding var keyValue: String
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    @State private var listValues: [String] = [""]
    @State private var hashPairs: [(field: String, value: String)] = [("", "")]
    @State private var setMembers: [String] = [""]
    @State private var zsetPairs: [(score: String, member: String)] = [("", "")]
    @State private var arrayPairs: [(index: String, value: String)] = [("", "")]
    @FocusState private var keyNameFocused: Bool

    private static let typeOptions = ["string", "list", "hash", "set", "zset", "array"]

    /// Why the Add button is disabled, if it is. Empty means submittable.
    private var disabledReason: String {
        if keyName.isEmpty {
            return "Enter a key name."
        }
        switch keyType {
        case "list" where !hasValidMembers:
            return "Add at least one element."
        case "hash" where !hasValidMembers:
            return "Add at least one field with a value."
        case "set" where !hasValidMembers:
            return "Add at least one member."
        case "zset" where !hasValidMembers:
            return "Add at least one member with a score."
        case "array" where !hasValidMembers:
            return "Add at least one element with a numeric index."
        default:
            return ""
        }
    }

    private var hasValidMembers: Bool {
        switch keyType {
        case "list":
            return listValues.contains { !$0.isEmpty }
        case "hash":
            return hashPairs.contains { !$0.field.isEmpty && !$0.value.isEmpty }
        case "set":
            return setMembers.contains { !$0.isEmpty }
        case "zset":
            return zsetPairs.contains { !$0.score.isEmpty && !$0.member.isEmpty }
        case "array":
            return arrayPairs.contains { Int($0.index) != nil && !$0.value.isEmpty }
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            formSection
        }
        .frame(width: AppSize.addKeySheetWidth)
        .presentationSurface()
        .onAppear { keyNameFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Add Key")
                .font(.headline)
            Spacer()
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: .tableAction))
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.xSmall)
    }

    // MARK: Form

    private var formSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            keyRow
            typeRow
            valueSection

            HStack(spacing: AppSpacing.small) {
                if !disabledReason.isEmpty {
                    Text(disabledReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    save()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!disabledReason.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, AppSpacing.small)
        }
        .padding(AppSpacing.large)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var keyRow: some View {
        HStack(spacing: AppSpacing.medium) {
            Text("Key")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: AppSize.formLabelWidthCompact, alignment: .leading)
            TextField("Key name", text: $keyName)
                .font(AppFont.monoSubheadline)
                .focused($keyNameFocused)
                .formFieldChrome(isFocused: $keyNameFocused)
        }
    }

    private var typeRow: some View {
        HStack(spacing: AppSpacing.medium) {
            Text("Type")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: AppSize.formLabelWidthCompact, alignment: .leading)
            OptionsPicker(
                "Select key type",
                selection: $keyType,
                options: Self.typeOptions,
                label: { redisKeyTypeTitle($0) }
            )
            .frame(maxWidth: AppSize.addKeyTypePickerWidth, alignment: .leading)
            Spacer()
        }
    }

    @ViewBuilder
    private var valueSection: some View {
        switch keyType {
        case "list":
            editSheetValueRows(
                values: $listValues,
                heading: "Elements",
                placeholder: { "Element \($0 + 1)" },
                addLabel: "Add Element"
            )
        case "hash":
            editSheetPairRows(
                pairs: Binding(
                    get: { hashPairs.map { (first: $0.field, second: $0.value) } },
                    set: { hashPairs = $0.map { (field: $0.first, value: $0.second) } }
                ),
                heading: "Fields",
                firstPlaceholder: "Field",
                secondPlaceholder: "Value",
                addLabel: "Add Field"
            )
        case "set":
            editSheetValueRows(
                values: $setMembers,
                heading: "Members",
                placeholder: { "Member \($0 + 1)" },
                addLabel: "Add Member"
            )
        case "zset":
            editSheetPairRows(
                pairs: Binding(
                    get: { zsetPairs.map { (first: $0.score, second: $0.member) } },
                    set: { zsetPairs = $0.map { (score: $0.first, member: $0.second) } }
                ),
                heading: "Members",
                firstPlaceholder: "Score",
                secondPlaceholder: "Member",
                addLabel: "Add Member",
                firstWidth: AppSize.formFieldWidth
            )
        case "array":
            editSheetPairRows(
                pairs: Binding(
                    get: { arrayPairs.map { (first: $0.index, second: $0.value) } },
                    set: { arrayPairs = $0.map { (index: $0.first, value: $0.second) } }
                ),
                heading: "Elements",
                firstPlaceholder: "Index",
                secondPlaceholder: "Value",
                addLabel: "Add Element",
                firstWidth: AppSize.formFieldWidth
            )
        default:
            stringRow
        }
    }

    private var stringRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.medium) {
            Text("Value")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: AppSize.formLabelWidthCompact, alignment: .leading)
            OwnFocusField { stringValueFocused in
                TextField("Value", text: $keyValue, axis: .vertical)
                    .lineLimit(3...6)
                    .font(AppFont.monoSubheadline)
                    .focused(stringValueFocused)
            }
        }
    }

    // MARK: Actions

    private func save() {
        switch keyType {
        case "list":
            onSave(keyName, keyType, listValues.joined(separator: "\n"))
        case "hash":
            let pairs = hashPairs.map { "\($0.field):\($0.value)" }.joined(separator: "\n")
            onSave(keyName, keyType, pairs)
        case "set":
            onSave(keyName, keyType, setMembers.joined(separator: "\n"))
        case "zset":
            let pairs = zsetPairs.map { "\($0.score):\($0.member)" }.joined(separator: "\n")
            onSave(keyName, keyType, pairs)
        case "array":
            let pairs = arrayPairs.map { "\($0.index):\($0.value)" }.joined(separator: "\n")
            onSave(keyName, keyType, pairs)
        default:
            onSave(keyName, keyType, keyValue)
        }
    }

}

private struct ConditionalWidth: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width)
        } else {
            content
        }
    }
}
