import SwiftUI

// MARK: - Bulk Member Delete Confirmation

/// Everything the bulk-delete confirmation needs besides the armed flag.
struct BulkMemberDeleteContext {
    let isProduction: Bool
    let count: Int
    /// Singular noun, e.g. "field", "element", "member".
    let noun: String
    let keyName: String
    let onConfirm: () -> Void
}

/// Shared confirmation flow for bulk member deletion in the collection
/// detail views: a plain dialog on normal environments, the typed
/// `ProductionConfirmView` on production. The caller keeps a single "armed"
/// flag; this modifier presents the right confirmation for the environment.
struct BulkMemberDeleteConfirmation: ViewModifier {
    @Binding var isArmed: Bool
    let context: BulkMemberDeleteContext

    @State private var confirmText = ""

    private var title: String {
        let noun = context.count == 1 ? context.noun : context.noun + "s"
        return "Delete \(context.count) \(noun)?"
    }

    private var message: String {
        let noun = context.count == 1 ? context.noun : context.noun + "s"
        return "This permanently deletes \(context.count) \(noun) from \"\(context.keyName)\"."
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title,
                isPresented: Binding(
                    get: { isArmed && !context.isProduction },
                    set: { if !$0 { isArmed = false } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    isArmed = false
                    context.onConfirm()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
            .sheet(
                isPresented: Binding(
                    get: { isArmed && context.isProduction },
                    set: {
                        if !$0 {
                            isArmed = false
                            confirmText = ""
                        }
                    }
                )
            ) {
                ProductionConfirmView(
                    title: title,
                    message: message,
                    confirmText: "DELETE",
                    confirmButtonTitle: "Delete",
                    input: $confirmText,
                    onConfirm: {
                        isArmed = false
                        confirmText = ""
                        context.onConfirm()
                    },
                    onCancel: {
                        isArmed = false
                        confirmText = ""
                    }
                )
                .presentationSizing(.form)
            }
    }
}

extension View {
    func bulkMemberDeleteConfirmation(
        isArmed: Binding<Bool>,
        context: BulkMemberDeleteContext
    ) -> some View {
        modifier(
            BulkMemberDeleteConfirmation(
                isArmed: isArmed,
                context: context
            )
        )
    }
}
