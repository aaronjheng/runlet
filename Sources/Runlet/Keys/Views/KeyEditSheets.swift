import SwiftUI

// MARK: - Edit Sheets

enum ListInsertPosition {
    case head, tail
}

struct AddHashFieldSheet: View {
    let key: String
    @Binding var field: String
    @Binding var value: String
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Text("Add Hash Field")
                .font(.headline)

            Form {
                TextField("Field name", text: $field)
                    .focused($fieldFocused)
                TextField("Value", text: $value, axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if field.isEmpty {
                    Text("Enter a field name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Add") { onSave(field, value) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(field.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .help(field.isEmpty ? "Enter a field name to enable" : "Add field")
            }
        }
        .padding(AppSpacing.large)
        .onAppear { fieldFocused = true }
    }
}

struct AddListElementSheet: View {
    let key: String
    @Binding var value: String
    @Binding var position: ListInsertPosition
    let onSave: (String, ListInsertPosition) -> Void
    let onCancel: () -> Void
    @FocusState private var valueFocused: Bool

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Text("Add List Element")
                .font(.headline)

            Form {
                TextField("Value", text: $value, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($valueFocused)
                Picker("Position", selection: $position) {
                    Text("Head (LPUSH)").tag(ListInsertPosition.head)
                    Text("Tail (RPUSH)").tag(ListInsertPosition.tail)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if value.isEmpty {
                    Text("Enter a value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Add") { onSave(value, position) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(value.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .help(value.isEmpty ? "Enter a value to enable" : "Add element")
            }
        }
        .padding(AppSpacing.large)
        .onAppear { valueFocused = true }
    }
}

struct AddSetMemberSheet: View {
    let key: String
    @Binding var member: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var memberFocused: Bool

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Text("Add Set Member")
                .font(.headline)

            Form {
                TextField("Member", text: $member, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($memberFocused)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if member.isEmpty {
                    Text("Enter a member.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Add") { onSave(member) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(member.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .help(member.isEmpty ? "Enter a member to enable" : "Add member")
            }
        }
        .padding(AppSpacing.large)
        .onAppear { memberFocused = true }
    }
}

struct AddZSetMemberSheet: View {
    let key: String
    @Binding var member: String
    @Binding var score: String
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    @FocusState private var scoreFocused: Bool

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Text("Add Sorted Set Member")
                .font(.headline)

            Form {
                TextField("Score", text: $score)
                    .focused($scoreFocused)
                TextField("Member", text: $member)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if member.isEmpty || score.isEmpty {
                    Text("Enter a score and member.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Add") { onSave(member, score) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(member.isEmpty || score.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .help(member.isEmpty || score.isEmpty ? "Enter a score and member to enable" : "Add member")
            }
        }
        .padding(AppSpacing.large)
        .onAppear { scoreFocused = true }
    }
}

// MARK: - Editable Identifiers

extension ListInsertPosition: Identifiable {
    var id: Int {
        switch self {
        case .head: return 0
        case .tail: return 1
        }
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
    @FocusState private var keyNameFocused: Bool

    private static let typeOptions = ["string", "list", "hash", "set", "zset"]

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
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formSection
        }
        .frame(width: AppSize.addKeySheetWidth)
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
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(AppSpacing.large)
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
                .textFieldStyle(.roundedBorder)
                .font(AppFont.monoSubheadline)
                .focused($keyNameFocused)
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
            valueRows(
                values: $listValues,
                heading: "Elements",
                placeholder: { "Element \($0 + 1)" },
                addLabel: "Add Element"
            )
        case "hash":
            pairRows(
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
            valueRows(
                values: $setMembers,
                heading: "Members",
                placeholder: { "Member \($0 + 1)" },
                addLabel: "Add Member"
            )
        case "zset":
            pairRows(
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
            TextField("Value", text: $keyValue, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .font(AppFont.monoSubheadline)
        }
    }

    private func valueRows(
        values: Binding<[String]>,
        heading: String,
        placeholder: @escaping (Int) -> String,
        addLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            sectionHeader(
                title: "\(heading) (\(values.wrappedValue.count))",
                addLabel: addLabel
            ) {
                values.wrappedValue.append("")
            }
            ForEach(values.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: AppSpacing.small) {
                    TextField(
                        placeholder(index),
                        text: Binding(
                            get: { values.wrappedValue[index] },
                            set: { values.wrappedValue[index] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.monoSubheadline)
                    removeButton(disabled: values.wrappedValue.count <= 1) {
                        values.wrappedValue.remove(at: index)
                    }
                }
            }
        }
    }

    private func pairRows(
        pairs: Binding<[(first: String, second: String)]>,
        heading: String,
        firstPlaceholder: String,
        secondPlaceholder: String,
        addLabel: String,
        firstWidth: CGFloat? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            sectionHeader(
                title: "\(heading) (\(pairs.wrappedValue.count))",
                addLabel: addLabel
            ) {
                pairs.wrappedValue.append(("", ""))
            }
            ForEach(pairs.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: AppSpacing.small) {
                    TextField(
                        firstPlaceholder,
                        text: Binding(
                            get: { pairs.wrappedValue[index].first },
                            set: { pairs.wrappedValue[index].first = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.monoSubheadline)
                    .modifier(ConditionalWidth(width: firstWidth))
                    TextField(
                        secondPlaceholder,
                        text: Binding(
                            get: { pairs.wrappedValue[index].second },
                            set: { pairs.wrappedValue[index].second = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.monoSubheadline)
                    removeButton(disabled: pairs.wrappedValue.count <= 1) {
                        pairs.wrappedValue.remove(at: index)
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, addLabel: String, action: @escaping () -> Void) -> some View {
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

    private func removeButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(IconButtonStyle(size: .row))
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help("Remove row")
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
