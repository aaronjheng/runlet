import SwiftUI

// MARK: - Lua Editor View

struct LuaEditorView: View {
    @Environment(TabState.self) private var tab
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    enum Mode {
        case create
        case edit(RedisFunctionLibrary)

        var isEdit: Bool {
            if case .edit = self { return true }
            return false
        }

        var title: String {
            isEdit ? "Edit Library" : "Load Library"
        }
    }

    enum DryRunState: Equatable {
        case idle
        case checking
        case ok
        case failed(String)
    }

    @State private var libraryName: String
    @State private var code: String
    @State private var replace: Bool
    @State private var dryRunState: DryRunState = .idle
    @State private var isWorking = false
    @State private var error: String?
    @State private var showingSaveConfirm = false
    @FocusState private var libraryNameFocused: Bool
    @State private var productionConfirmText = ""

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _libraryName = State(initialValue: "mylib")
            _code = State(initialValue: Self.template(name: "mylib"))
            _replace = State(initialValue: false)
        case .edit(let library):
            _libraryName = State(initialValue: library.name)
            _code = State(initialValue: library.code)
            _replace = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            nameRow
            Divider()
            editor
            statusBar
            if let error {
                ErrorBanner(message: error, dismissAction: { self.error = nil })
            }
            Divider()
            actions
        }
        .frame(width: 700, height: 540)
        .confirmationDialog(
            mode.isEdit ? "Save library \"\(libraryName)\"?" : "Load library \"\(libraryName)\"?",
            isPresented: Binding(
                get: { showingSaveConfirm && !isProduction },
                set: { showingSaveConfirm = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button(mode.isEdit ? "Save" : "Load") {
                Task { await save() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if mode.isEdit {
                Text("This will overwrite the existing library with the edited code.")
            } else {
                Text("This will load a new library. If a library with this name already exists, it will be replaced.")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { showingSaveConfirm && isProduction },
                set: {
                    if !$0 {
                        showingSaveConfirm = false
                        productionConfirmText = ""
                    }
                }
            )
        ) {
            ProductionConfirmView(
                title: "\(mode.isEdit ? "Save" : "Load") library \"\(libraryName)\"?",
                message: "This will \(mode.isEdit ? "overwrite" : "load") a library on a production server. This action cannot be undone.",
                confirmText: mode.isEdit ? "SAVE" : "LOAD",
                confirmButtonTitle: mode.isEdit ? "Save" : "Load",
                input: $productionConfirmText,
                onConfirm: {
                    Task { await save() }
                    showingSaveConfirm = false
                    productionConfirmText = ""
                },
                onCancel: {
                    showingSaveConfirm = false
                    productionConfirmText = ""
                }
            )
            .presentationSizing(.form)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "curlybraces")
                .foregroundStyle(.tint)
            Text(mode.title)
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .help("Close (Esc)")
        }
        .padding(AppSpacing.large)
    }

    // MARK: Name + replace

    private var nameRow: some View {
        HStack(spacing: AppSpacing.medium) {
            HStack(spacing: AppSpacing.small) {
                Text("Library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("library name", text: $libraryName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .focused($libraryNameFocused)
                    .onChange(of: libraryName) { _, _ in
                        syncShebang()
                    }
            }
            Spacer()
            if !mode.isEdit {
                Toggle("Replace existing", isOn: $replace)
                    .help("Overwrite a library with the same name (FUNCTION LOAD REPLACE)")
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.small)
    }

    // MARK: Editor

    private var editor: some View {
        SyntaxTextEditor(
            text: $code,
            tokenizer: TreeSitterLuaHighlighter.shared,
            completionProvider: LuaCompletionProvider()
        )
        .background(AppColor.codeBackground)
        .padding(AppSpacing.medium)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: AppSpacing.small) {
            Text("\(code.count) chars")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            dryRunIndicator
        }
        .font(.caption)
        .controlSize(.small)
        .imageScale(.small)
        .padding(.horizontal, AppSpacing.small)
        .frame(minHeight: AppSize.footerHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private var dryRunIndicator: some View {
        switch dryRunState {
        case .idle:
            Text("Type Lua code — Tab completes redis.* names")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .checking:
            HStack(spacing: AppSpacing.xSmall) {
                ProgressView().controlSize(.small)
                Text("Checking syntax…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ok:
            Label("Syntax OK", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(AppColor.success)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(AppColor.error)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(message)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: AppSpacing.small) {
            Button {
                Task { await runDryRun() }
            } label: {
                Label("Dry Run", systemImage: "stethoscope")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isWorking || trimmedCode.isEmpty)

            Spacer()

            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
            Button {
                showingSaveConfirm = true
            } label: {
                Label(mode.isEdit ? "Save" : "Load", systemImage: mode.isEdit ? "checkmark" : "arrow.down.doc")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || trimmedCode.isEmpty)
        }
        .padding(AppSpacing.large)
    }

    // MARK: Logic

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isProduction: Bool {
        tab.selectedConnection?.environment == .production
    }

    /// Keeps the `#!lua name=<name>` shebang in sync with the library name field.
    private func syncShebang() {
        var lines = code.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("#!lua name=") {
            lines[0] = "#!lua name=\(libraryName)"
            code = lines.joined(separator: "\n")
        }
    }

    private func runDryRun() async {
        isWorking = true
        dryRunState = .checking
        if let message = await tab.dryRunFunction(code: code) {
            dryRunState = .failed(message)
        } else {
            dryRunState = .ok
        }
        isWorking = false
    }

    private func save() async {
        isWorking = true
        error = nil
        do {
            try await tab.loadFunctionLibrary(code: code, replace: replace)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isWorking = false
    }

    private static func template(name: String) -> String {
        """
        #!lua name=\(name)

        redis.register_function('my_func', function(keys, args)
            return #keys + #args
        end)
        """
    }
}
