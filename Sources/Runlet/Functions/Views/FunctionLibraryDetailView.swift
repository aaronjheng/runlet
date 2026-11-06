import Plume
import SwiftUI

// MARK: - Function Library Detail View

/// Detail pane for Redis Functions: header + functions list stay on screen
/// while the code area below is always the editor, so editing and reading
/// share one surface. The same view drives both editing an existing library
/// and drafting a new one — only the header and save semantics differ.
struct FunctionLibraryDetailView: View {
    enum Mode {
        case existing(RedisFunctionLibrary)
        case new

        var isNew: Bool {
            if case .new = self { return true }
            return false
        }

        var existingLibrary: RedisFunctionLibrary? {
            if case .existing(let library) = self { return library }
            return nil
        }
    }

    enum DryRunState: Equatable {
        case idle
        case checking
        case ok
        case failed(String)
    }

    @Environment(TabState.self) private var tab
    let mode: Mode
    var onDirtyChanged: ((Bool) -> Void)?
    /// For `.new` mode: called with the created library name after a
    /// successful load so the parent can exit create mode and select it.
    var onSaved: ((String) -> Void)?
    /// For `.new` mode: discard the draft and exit create mode.
    var onCancel: (() -> Void)?

    @State private var draftCode: String
    @State private var libraryName: String
    @State private var replace: Bool
    @State private var dryRunState: DryRunState = .idle
    @State private var isWorking = false
    @State private var error: String?
    @State private var showingProductionConfirm = false
    @State private var productionConfirmText = ""
    @State private var showingDeleteConfirm = false
    @State private var showingCallSheet = false
    @State private var isFunctionsExpanded = false
    @FocusState private var libraryNameFocused: Bool

    /// The draft as it started, for dirty detection in `.new` mode. In
    /// `.existing` mode dirty is measured against the live `library.code`
    /// so a successful save clears itself once the list refreshes.
    private let originalCode: String
    private let originalName: String

    init(
        mode: Mode,
        onDirtyChanged: ((Bool) -> Void)? = nil,
        onSaved: ((String) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.onDirtyChanged = onDirtyChanged
        self.onSaved = onSaved
        self.onCancel = onCancel
        switch mode {
        case .existing(let library):
            _draftCode = State(initialValue: library.code)
            _libraryName = State(initialValue: library.name)
            _replace = State(initialValue: true)
            originalCode = library.code
            originalName = library.name
        case .new:
            let initialCode = Self.template(name: "mylib")
            _draftCode = State(initialValue: initialCode)
            _libraryName = State(initialValue: "mylib")
            _replace = State(initialValue: false)
            originalCode = initialCode
            originalName = "mylib"
        }
    }

    private var isProduction: Bool {
        tab.selectedConnection?.environment == .production
    }

    private var isDirty: Bool {
        if mode.isNew {
            draftCode != originalCode || libraryName != originalName
        } else {
            draftCode != mode.existingLibrary?.code
        }
    }

    private var expectedConfirmText: String { mode.isNew ? "LOAD" : "SAVE" }

    private var trimmedCode: String {
        draftCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let library = mode.existingLibrary, !library.functions.isEmpty {
                functionsSection
                Divider()
            }
            editorPane
        }
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $showingCallSheet) {
            if let library = mode.existingLibrary {
                FunctionCallView(library: library)
            }
        }
        .confirmationDialog(
            "Delete library \"\(mode.existingLibrary?.name ?? "")\"",
            isPresented: Binding(
                get: { showingDeleteConfirm && !isProduction },
                set: { showingDeleteConfirm = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let library = mode.existingLibrary else { return }
                Task {
                    do {
                        try await tab.deleteFunctionLibrary(name: library.name)
                    } catch {
                        tab.functionsError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let nodes = mode.existingLibrary?.nodes, !nodes.isEmpty {
                Text(
                    "This will delete the library from \(nodes.count) primary node(s). This action cannot be undone."
                )
            } else {
                Text("This action cannot be undone.")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { showingDeleteConfirm && isProduction },
                set: {
                    if !$0 {
                        showingDeleteConfirm = false
                        productionConfirmText = ""
                    }
                }
            )
        ) {
            if let library = mode.existingLibrary {
                ProductionConfirmView(
                    title: "Delete library \"\(library.name)\"",
                    message: (library.nodes ?? []).isEmpty
                        ? "This will permanently delete the library. This action cannot be undone."
                        : "This will permanently delete the library from \((library.nodes ?? []).count)"
                            + "primary node(s). This action cannot be undone.",
                    confirmText: "DELETE",
                    confirmButtonTitle: "Delete",
                    input: $productionConfirmText,
                    onConfirm: {
                        Task {
                            do {
                                try await tab.deleteFunctionLibrary(name: library.name)
                            } catch {
                                tab.functionsError = error.localizedDescription
                            }
                        }
                        showingDeleteConfirm = false
                        productionConfirmText = ""
                    },
                    onCancel: {
                        showingDeleteConfirm = false
                        productionConfirmText = ""
                    }
                )
                .presentationSizing(.form)
            }
        }
        .onAppear { onDirtyChanged?(isDirty) }
        .onChange(of: draftCode) { _, _ in onDirtyChanged?(isDirty) }
        .onChange(of: libraryName) { _, _ in
            if mode.isNew { syncShebang() }
            onDirtyChanged?(isDirty)
        }
        .onChange(of: mode.existingLibrary?.code ?? "") { old, new in
            if !mode.isNew, draftCode == old {
                draftCode = new
            }
            onDirtyChanged?(isDirty)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if mode.isNew {
            newHeader
        } else if let library = mode.existingLibrary {
            existingHeader(library)
        }
    }

    private func existingHeader(_ library: RedisFunctionLibrary) -> some View {
        HStack(spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                HStack(spacing: AppSpacing.small) {
                    Badge(text: library.engine, isLoading: library.engine.isEmpty)
                    Text(library.name)
                        .font(.title3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isDirty {
                        Circle()
                            .fill(AppColor.warning)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                }
                HStack(spacing: AppSpacing.compact) {
                    HStack(spacing: AppSpacing.xxSmall) {
                        Image(systemName: "number")
                        Text("\(library.functionCount) function\(library.functionCount == 1 ? "" : "s")")
                    }
                    .foregroundStyle(.secondary)
                    if library.isReadOnly {
                        Badge(
                            text: "Read-only",
                            foregroundColor: AppColor.success,
                            backgroundColor: AppColor.badgeBackground(AppColor.success)
                        )
                    }
                    if let nodes = library.nodes, !nodes.isEmpty {
                        HStack(spacing: AppSpacing.xSmall) {
                            Image(systemName: "server.rack")
                            Text(nodes.map(\.address).joined(separator: ", "))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(nodes.map(\.address).joined(separator: ", "))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            Spacer(minLength: 0)
            HStack(spacing: AppSpacing.small) {
                Button {
                    showingCallSheet = true
                } label: {
                    Label("Call", systemImage: "play")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(library.functions.isEmpty)
                .help("Run a function (FCALL)")
                DeleteIconButton(action: { showingDeleteConfirm = true }, helpText: "Delete library")
                    .toolbarCapsule()
            }
        }
        .padding(AppSpacing.small)
    }

    /// New-library header mirrors the existing header's two-row height so the
    /// pane reads as the same surface: title row on top, field row below.
    private var newHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack(spacing: AppSpacing.small) {
                Badge(text: "lua")
                Text("New Library")
                    .font(.title3)
                if isDirty {
                    Circle()
                        .fill(AppColor.warning)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
                Spacer(minLength: 0)
                Button {
                    onCancel?()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: .tableAction))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close")
                .help("Discard and close")
            }
            HStack(spacing: AppSpacing.compact) {
                HStack(spacing: AppSpacing.small) {
                    Text("Library")
                        .foregroundStyle(.secondary)
                    TextField("library name", text: $libraryName)
                        .frame(maxWidth: 220)
                        .focused($libraryNameFocused)
                        .formFieldChrome(isFocused: $libraryNameFocused)
                }
                Spacer(minLength: 0)
                Toggle("Replace existing", isOn: $replace)
                    .toggleStyle(.switch)
                    .help("Overwrite a library with the same name (FUNCTION LOAD REPLACE)")
            }
            .font(.subheadline)
        }
        .padding(AppSpacing.small)
    }

    // MARK: Functions

    private var functionsSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isFunctionsExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isFunctionsExpanded ? 90 : 0))
                    Image(systemName: "curlybraces")
                        .foregroundStyle(.tint)
                    Text("Functions")
                        .font(.headline)
                    Spacer(minLength: 0)
                    Text("\(mode.existingLibrary?.functionCount ?? 0)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(AppSpacing.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverBackground()
            .help(isFunctionsExpanded ? "Hide functions" : "Show functions")

            if isFunctionsExpanded, let library = mode.existingLibrary {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(library.functions.enumerated()), id: \.element.id) { index, function in
                        functionRow(function)
                        if index < library.functions.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func functionRow(_ function: RedisFunction) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.small) {
            Image(systemName: "f.cursive")
                .foregroundStyle(.tint)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(function.name)
                        .font(AppFont.monoSubheadline)
                    if function.isReadOnly {
                        Badge(
                            text: "no-writes",
                            foregroundColor: AppColor.success,
                            backgroundColor: AppColor.badgeBackground(AppColor.success)
                        )
                    }
                }
                if let description = function.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.small)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Function Name") {
                copyToPasteboard(function.name)
            }
            Button("Copy FCALL Command") {
                copyToPasteboard("FCALL \(function.name) 0")
            }
        }
        .help(function.name)
    }

    // MARK: Editor pane (always editable — view and edit are one surface)

    @State private var completionBridge = LuaCompletionBridge()
    @State private var editorStats: Editor.Stats?
    /// A formatting diagnostic from ⌥⇧F (the library did not parse); shown
    /// in the same banner as save/dry-run errors until dismissed.
    @State private var formatError: String?

    private var editorMarkers: [EditorMarker] {
        var markers: [EditorMarker] = []
        if case .failed(let message) = dryRunState {
            markers.append(Self.editorMarker(for: message, in: draftCode))
        }
        if let formatError {
            markers.append(Self.editorMarker(for: formatError, in: draftCode))
        }
        return markers
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            Editor(
                text: $draftCode,
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
                scrollBeyondLastLine: true,
                occurrencesHighlight: true,
                colorDecorators: true,
                bracketPairColorization: true,
                renderFinalNewline: .boundary
            )
            .frame(maxHeight: .infinity)
            // Leading breathing only: Plume already insets text 6pt from its
            // edges, and the overview ruler must sit flush to the right edge.
            .padding(.leading, AppSpacing.medium)
            .background(AppColor.codeBackground)

            statusBar
            if let error {
                ErrorBanner(message: error, dismissAction: { self.error = nil })
            } else if let formatError {
                ErrorBanner(message: formatError, dismissAction: { self.formatError = nil })
            }
            if showingProductionConfirm {
                productionConfirm
                Divider()
            }
            Divider()
            actions
        }
    }

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

    private var productionConfirm: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(AppColor.error)
                Text("\(mode.isNew ? "Load" : "Save") library \"\(libraryName)\" on production?")
                    .font(.subheadline.weight(.semibold))
            }
            Text(
                "This will \(mode.isNew ? "load" : "overwrite") a library on a production server. "
                    + "This action cannot be undone. Type \"\(expectedConfirmText)\" to confirm:"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            TextField("Type \(expectedConfirmText)", text: $productionConfirmText)
                .onSubmit {
                    if productionConfirmText == expectedConfirmText {
                        Task { await saveDraft() }
                    }
                }
            HStack(spacing: AppSpacing.small) {
                Button {
                    showingProductionConfirm = false
                    productionConfirmText = ""
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isWorking)
                Spacer()
                Button {
                    Task { await saveDraft() }
                } label: {
                    Label(
                        mode.isNew ? "Load" : "Save",
                        systemImage: mode.isNew ? "arrow.down.doc" : "checkmark"
                    )
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking || productionConfirmText != expectedConfirmText)
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColor.error.opacity(0.08))
    }

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
            Button("Cancel") { cancel() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isWorking || (!mode.isNew && !isDirty))
                .help(mode.isNew ? "Discard draft and close" : "Discard edits and restore the saved code")
            Button {
                if isProduction {
                    productionConfirmText = ""
                    showingProductionConfirm = true
                } else {
                    Task { await saveDraft() }
                }
            } label: {
                Label(
                    mode.isNew ? "Load" : "Save",
                    systemImage: mode.isNew ? "arrow.down.doc" : "checkmark"
                )
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking || trimmedCode.isEmpty || showingProductionConfirm || (!mode.isNew && !isDirty))
        }
        .padding(AppSpacing.large)
    }

    // MARK: Logic

    private func cancel() {
        if mode.isNew {
            onCancel?()
        } else {
            revert()
        }
    }

    private func revert() {
        draftCode = mode.existingLibrary?.code ?? originalCode
        dryRunState = .idle
        error = nil
        formatError = nil
        showingProductionConfirm = false
        productionConfirmText = ""
    }

    /// Keeps the `#!lua name=<name>` shebang in sync with the library name field.
    private func syncShebang() {
        var lines = draftCode.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("#!lua name=") {
            lines[0] = "#!lua name=\(libraryName)"
            draftCode = lines.joined(separator: "\n")
        }
    }

    private func runDryRun() async {
        isWorking = true
        dryRunState = .checking
        if let message = await tab.dryRunFunction(code: draftCode) {
            dryRunState = .failed(message)
        } else {
            dryRunState = .ok
        }
        isWorking = false
    }

    private func saveDraft() async {
        isWorking = true
        error = nil
        do {
            try await tab.loadFunctionLibrary(code: draftCode, replace: mode.isNew ? replace : true)
            showingProductionConfirm = false
            productionConfirmText = ""
            if mode.isNew {
                onSaved?(libraryName)
            }
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

    // MARK: Marker helpers

    /// One error marker on the line the message names, falling back to the
    /// first line when it carries no position.
    private static func editorMarker(for message: String, in code: String) -> EditorMarker {
        EditorMarker(
            severity: .error,
            range: lineRange(errorLine(in: message) ?? 1, in: code),
            message: message)
    }

    private static func errorLine(in message: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: ":([0-9]+):") else { return nil }
        let ns = message as NSString
        let matches = regex.matches(in: message, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first, first.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: first.range(at: 1)))
    }

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
}
