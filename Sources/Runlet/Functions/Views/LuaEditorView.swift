import Plume
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
            nameRow
            Divider()
            editor
            statusBar
            if let error {
                ErrorBanner(message: error, dismissAction: { self.error = nil })
            } else if let formatError {
                ErrorBanner(message: formatError, dismissAction: { self.formatError = nil })
            }
            Divider()
            actions
        }
        .frame(width: 700, height: 540)
        .presentationSurface()
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
            .buttonStyle(IconButtonStyle(size: .tableAction))
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .help("Close (Esc)")
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.xSmall)
    }

    // MARK: Name + replace

    private var nameRow: some View {
        HStack(spacing: AppSpacing.medium) {
            HStack(spacing: AppSpacing.small) {
                Text("Library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("library name", text: $libraryName)
                    .frame(maxWidth: 220)
                    .focused($libraryNameFocused)
                    .formFieldChrome(isFocused: $libraryNameFocused)
                    .onChange(of: libraryName) { _, _ in
                        syncShebang()
                    }
            }
            Spacer()
            if !mode.isEdit {
                Toggle("Replace existing", isOn: $replace)
                    // Default checkbox style renders unchecked as a flat gray
                    // square that reads as disabled; a switch keeps the knob
                    // affordance in both states.
                    .toggleStyle(.switch)
                    .help("Overwrite a library with the same name (FUNCTION LOAD REPLACE)")
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.small)
    }

    // MARK: Editor

    /// The Lua editing surface: Plume's generic editor over the host-defined
    /// `lua` syntax profile, with the `redis.`-aware completion bridge.
    @State private var completionBridge = LuaCompletionBridge()
    @State private var editorStats: Editor.Stats?
    /// A formatting diagnostic from ⌥⇧F (the library did not parse); shown
    /// in the same banner as save/dry-run errors until dismissed.
    @State private var formatError: String?

    /// Diagnostics pushed into the editor (Monaco: `setModelMarkers`): the
    /// dry-run result and the formatting error, each placed on the line its
    /// message names. Rendered as squiggles, gutter dots, and an overview
    /// ruler tick alongside the grammar's own syntax errors.
    private var editorMarkers: [EditorMarker] {
        var markers: [EditorMarker] = []
        if case .failed(let message) = dryRunState {
            markers.append(editorMarker(for: message))
        }
        if let formatError {
            markers.append(editorMarker(for: formatError))
        }
        return markers
    }

    /// One error marker on the line the message names, falling back to the
    /// first line when it carries no position.
    private func editorMarker(for message: String) -> EditorMarker {
        EditorMarker(
            severity: .error,
            range: Self.lineRange(Self.errorLine(in: message) ?? 1, in: code),
            message: message)
    }

    /// Redis Lua diagnostics name a position as `<script>:<line>: message`;
    /// the first such number is the offending line (best-effort - a message
    /// without one falls back to the first line).
    private static func errorLine(in message: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: ":([0-9]+):") else { return nil }
        let ns = message as NSString
        let matches = regex.matches(in: message, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first, first.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: first.range(at: 1)))
    }

    /// The UTF-16 range of `line` (1-based) in `text`, clamped to the
    /// document; an empty line yields a zero-length range (no squiggle, but
    /// the marker still counts).
    private static func lineRange(_ line: Int, in text: String) -> NSRange {
        let ns = text as NSString
        var current = 1
        var index = 0
        while index < ns.length, current < line {
            if ns.character(at: index) == 0x0A { current += 1 }
            index += 1
        }
        guard current == line, index <= ns.length else {
            let start = max(ns.length - 1, 0)
            return NSRange(location: start, length: min(1, ns.length))
        }
        var end = index
        while end < ns.length, ns.character(at: end) != 0x0A { end += 1 }
        return NSRange(location: index, length: end - index)
    }

    private var editor: some View {
        Editor(
            text: $code,
            syntax: .lua,
            fillsContainer: true,
            font: .monoBody,
            placeholder: "local lib = {}\n\nfunction lib.handler(keys, args)\n  return redis.call('ping')\nend",
            formatHandler: { source in
                do {
                    return try LuaFormatter.format(source)
                } catch let error as LuaFormatter.LuaFormatError {
                    throw TextFormatError(message: error.message)
                }
            },
            formatActionName: "Format Script",
            onFormatError: { formatError = $0 },
            suggestFactory: { completionBridge },
            onStatsChange: { editorStats = $0 },
            markers: editorMarkers,
            showsOverviewRuler: true,
            tabSize: 4,
            renderLineHighlight: .all,
            scrollBeyondLastLine: true
        )
        // fillsContainer: the editor takes the sheet's leftover height and
        // scrolls when content overflows. (The old collapse-to-invisible
        // defect here was Plume's internal auto-grow cap + lazy-layout
        // under-reporting, both fixed in the package.) The background sits
        // OUTSIDE the padding, so the pane reads edge-to-edge down to the
        // status bar instead of floating on gray margins.
        .padding(AppSpacing.medium)
        .background(AppColor.codeBackground)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: AppSpacing.small) {
            Text(editorStats.map { "\($0.characters) chars · line \($0.line), col \($0.column)" } ?? "")
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
        .background(AppColor.secondaryBackground)
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
                .buttonStyle(SecondaryButtonStyle())
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
