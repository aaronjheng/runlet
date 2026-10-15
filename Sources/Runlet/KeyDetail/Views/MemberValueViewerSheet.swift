import SwiftUI

// MARK: - Member Value Viewer

/// Identity for an open member-value viewer sheet: which row and its raw
/// value. Shared by the collection detail views.
struct MemberValueContext: Identifiable {
    let id = UUID()
    /// Human label of the row, e.g. "Field: user:name" or "Index 3".
    let label: String
    let value: String
    /// Opens the row's inline editor after the viewer closes; nil for
    /// read-only placements.
    let onEdit: (() -> Void)?
}

/// Full-value viewer for hash/list/set/zset/array members. Collection tables
/// truncate cell text to two lines, so long values (a JSON blob in a hash
/// field, for instance) were previously unreadable without entering edit
/// mode. The viewer reuses the string detail view's formatters, including
/// tree-sitter JSON highlighting.
struct MemberValueViewerSheet: View {
    let keyName: String
    let context: MemberValueContext

    @State private var format: StringValueFormat = .json
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let jsonPretty = format == .json ? StringValueFormatter.prettyPrintedJSON(context.value) : nil

        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text(context.label)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(keyName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)

                if let onEdit = context.onEdit {
                    Button("Edit", systemImage: "square.and.pencil") {
                        dismiss()
                        onEdit()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(IconButtonStyle(weight: .semibold))
                    .help("Edit this value in place")
                }

                Button("Close", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Close viewer")
            }
            .panelToolbar(horizontalPadding: AppSpacing.small)

            Divider()

            ScrollView {
                if let jsonPretty {
                    SelectableText(
                        text: jsonPretty,
                        font: AppFont.dataCellNSFont,
                        tokenizer: TreeSitterJsonHighlighter.shared
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.large)
                } else {
                    let decoded = StringValueFormatter.decoded(context.value, format: format)
                    if let error = decoded.error {
                        ErrorBanner(message: error)
                            .padding(.horizontal, AppSpacing.large)
                            .padding(.top, AppSpacing.small)
                    }
                    Text(decoded.error == nil ? decoded.text : context.value)
                        .font(AppFont.dataCell)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.large)
                }
            }
            .contextMenu {
                Button("Copy Value") {
                    copyToPasteboard(context.value)
                }
            }

            Divider()

            PanelFooterBar {
                OptionsPicker(
                    "Value format",
                    selection: $format,
                    options: StringValueFormat.allCases,
                    label: \.title
                )
                Spacer()
            }
        }
    }
}
