import AppKit
import SwiftUI

// MARK: - Production Confirmation

/// A typed-confirmation sheet for consequential actions on production databases.
/// Shared by Keys, Key Detail views, and Function Library views.
struct ProductionConfirmView: View {
    let title: String
    let message: String
    let confirmText: String
    /// Title of the destructive confirm button, e.g. `Delete`, `Save`, `Load`.
    /// Always names the action so it never contradicts the title.
    let confirmButtonTitle: String
    @Binding var input: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.largeTitle)
                .foregroundStyle(AppColor.error)

            Text(title)
                .font(.title2)
                .bold()

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 0) {
                Image(systemName: "shield")
                    .foregroundStyle(AppColor.error)
                Text("This is a PRODUCTION database.")
                    .font(.subheadline)
                    .foregroundStyle(AppColor.error)
            }

            HStack(spacing: AppSpacing.xSmall) {
                Text("Type \"\(confirmText)\" to confirm:")
                    .font(.subheadline)
                Spacer()
            }

            TextField("", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .onSubmit(confirmIfValid)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmButtonTitle, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input != confirmText)
            }
        }
        .padding(AppSpacing.large)
        .frame(width: AppSize.productionConfirmWidth)
        .onAppear { isInputFocused = true }
    }

    private func confirmIfValid() {
        if input == confirmText {
            onConfirm()
        }
    }
}
