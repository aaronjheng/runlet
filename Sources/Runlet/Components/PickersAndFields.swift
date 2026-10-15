import AppKit
import SwiftUI

// MARK: - Stable screenshot pickers

/// A two-option segmented picker drawn entirely in SwiftUI so it captures reliably.
struct BinaryTogglePicker<Option: Hashable & Sendable, FirstLabel: View, SecondLabel: View>: View {
    let options: (first: Option, second: Option)
    let firstLabel: FirstLabel
    let secondLabel: SecondLabel
    let firstHelp: String?
    let secondHelp: String?
    @Binding var selection: Option

    init(
        selection: Binding<Option>,
        first: Option,
        second: Option,
        firstHelp: String? = nil,
        secondHelp: String? = nil,
        @ViewBuilder firstLabel: () -> FirstLabel,
        @ViewBuilder secondLabel: () -> SecondLabel
    ) {
        self._selection = selection
        self.options = (first, second)
        self.firstHelp = firstHelp
        self.secondHelp = secondHelp
        self.firstLabel = firstLabel()
        self.secondLabel = secondLabel()
    }

    var body: some View {
        HStack(spacing: 0) {
            ToggleButton(
                isSelected: selection == options.first,
                helpText: firstHelp,
                backgroundShape: UnevenRoundedRectangle(
                    topLeadingRadius: AppRadius.medium,
                    bottomLeadingRadius: AppRadius.medium,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            ) {
                selection = options.first
            } label: {
                firstLabel
            }

            ToggleButton(
                isSelected: selection == options.second,
                helpText: secondHelp,
                backgroundShape: UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: AppRadius.medium,
                    topTrailingRadius: AppRadius.medium,
                    style: .continuous
                )
            ) {
                selection = options.second
            } label: {
                secondLabel
            }
        }
        .frame(height: AppSize.refreshControlHeight)
        .background(AppColor.pillBackground, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }
}

private struct ToggleButton<Label: View>: View {
    let isSelected: Bool
    let helpText: String?
    let backgroundShape: UnevenRoundedRectangle
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 13, weight: .medium))
                .imageScale(.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(
            isSelected
                ? AppColor.controlFillBackground
                : isHovering ? AppColor.hoverBackground : Color.clear,
            in: backgroundShape
        )
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .optionalHelp(helpText)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

/// A unified search/filter text field used across all panels.
///
/// When `onSearch` is provided the magnifying-glass icon becomes a tappable
/// search button and Return triggers the callback — suitable for server-side
/// filtering. When `onSearch` is `nil` the field acts as a local filter;
/// the parent simply observes `text` changes.
struct FilterField: View {
    @Binding var text: String
    let placeholder: String
    var onSearch: (() -> Void)?
    /// Optional externally-owned focus binding (e.g. ⌘F from the parent).
    /// When provided it replaces the internal focus state entirely.
    private var externalFocus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool
    @State private var isHovering = false

    init(
        _ placeholder: String,
        text: Binding<String>,
        focus: FocusState<Bool>.Binding? = nil,
        onSearch: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.onSearch = onSearch
        self.externalFocus = focus
    }

    private var isFocused: Bool {
        externalFocus?.wrappedValue ?? internalFocus
    }

    private var focusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $internalFocus
    }

    /// Right-side icon slots: clear button (when text is non-empty) + search/focus button.
    /// Both slots are 22pt buttons so server-side and local-filter variants share geometry.
    private var showsClearButton: Bool { !text.isEmpty }

    private var borderColor: Color {
        if isFocused {
            return .accentColor
        }
        return isHovering ? AppColor.fieldHoverBorder : Color(nsColor: .separatorColor)
    }

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                // Same font + vertical padding as Primary/SecondaryButtonStyle
                // labels, so the field always matches same-row button height
                // without a hardcoded frame.
                .font(.system(.body, design: .default))
                .focused(focusBinding)
                .focusEffectDisabled()
                .onSubmit { onSearch?() }
                .lineLimit(1)
            if showsClearButton {
                FilterFieldIconButton(
                    title: "Clear Filter",
                    systemImage: "xmark.circle.fill",
                    helpText: "Clear filter"
                ) {
                    text = ""
                    onSearch?()
                }
            }
            if let onSearch {
                FilterFieldIconButton(
                    title: "Search",
                    systemImage: "magnifyingglass",
                    helpText: "Search",
                    action: onSearch
                )
            } else {
                // No server-side search: keep the same look and hover
                // affordance as the search button so the two variants
                // can't be mistaken, and focus the field on click.
                FilterFieldIconButton(
                    title: "Focus Filter",
                    systemImage: "magnifyingglass",
                    helpText: "Focus filter field"
                ) {
                    focusBinding.wrappedValue = true
                }
            }
        }
        .padding(.leading, AppSpacing.small)
        .padding(.trailing, AppSpacing.small)
        .padding(.vertical, AppSpacing.mini)
        .background {
            // Field surface stays constant across hover (white in light,
            // #212121 in dark): no darkening wash — hover reads through the
            // border brightening and the trailing icon buttons.
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(AppColor.codeBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? AppBorderWidth.focused : AppBorderWidth.regular)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusBinding.wrappedValue = true }
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
        .animation(AppAnimation.quick, value: isFocused)
    }
}

/// Trailing icon button inside `FilterField`.
private struct FilterFieldIconButton: View {
    let title: String
    let systemImage: String
    let helpText: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .frame(
                minWidth: AppSize.filterFieldIconWidth,
                maxWidth: AppSize.filterFieldIconWidth
            )
            .contentShape(Rectangle())
            .background {
                // Square hover pill painted behind the glyph: fixed
                // `filterFieldHoverSquare` side so it reads as a proper
                // square (not a glyph-hugging sliver) without growing the
                // field's layout.
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isHovering ? AppColor.iconHoverBackground : Color.clear)
                    .frame(
                        width: AppSize.filterFieldHoverSquare,
                        height: AppSize.filterFieldHoverSquare
                    )
            }
            .onHover { isHovering = $0 }
            .clickCursor()
            .animation(AppAnimation.quick, value: isHovering)
            .help(helpText)
    }
}

// MARK: - Form Field Chrome

/// Hover/focus chrome for fields inside sheets and grouped forms, tracking
/// Canoe's field tiers: idle draws nothing so the form cell shows through;
/// hover lifts to `fieldHoverBackground` with a `fieldHoverBorder` outline;
/// focus switches to the accent ring over `fieldFocusBackground`. Call sites
/// pass their own `@FocusState` binding so sheet initial-focus keeps working.
private struct FormFieldChrome: ViewModifier {
    @FocusState.Binding var isFocused: Bool
    @State private var isHovering = false
    /// Standalone layouts (custom sheet rows, popovers) have no container of
    /// their own, so the chrome draws a rest hairline to keep the field
    /// visible. Inside a grouped `Form` the cell IS the visible box — an
    /// added rest border would nest a second rectangle inside it — so those
    /// call sites pass `false` and only hover/focus draw.
    var idleBorder: Bool = true

    func body(content: Content) -> some View {
        content
            // The system focus effect (a thick blue glow hugging the field)
            // would sit outside the themed border and dwarf it — the same
            // reason `FilterField` disables it. The chrome's own accent ring
            // carries the focus signal instead.
            .focusEffectDisabled()
            // Fields wrapped by the chrome must never draw a bezel of their
            // own: the default automatic style inside a grouped `Form` (and
            // on multiline fields) paints a second hairline box nested
            // inside the chrome border — the double-box artifact.
            .textFieldStyle(.plain)
            .scrollContentBackground(.hidden)
            // Bezel inset: keeps the text off the drawn border the way the
            // system rounded bezel does, and lands single-line rows on the
            // same 28pt rhythm as `OptionsPicker`/`RefreshControl`.
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.mini)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(fieldBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(
                        fieldBorderColor,
                        lineWidth: isFocused ? AppBorderWidth.focused : AppBorderWidth.regular
                    )
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: isHovering)
            .animation(AppAnimation.quick, value: isFocused)
    }

    private var fieldBackground: Color {
        if isFocused { return AppColor.fieldFocusBackground }
        if isHovering { return AppColor.fieldHoverBackground }
        // Rest keeps the field's own surface (white in light, the #212121
        // content base in dark) so fields read as solid boxes on the page.
        return AppColor.codeBackground
    }

    private var fieldBorderColor: Color {
        if isFocused { return .accentColor }
        if isHovering { return AppColor.fieldHoverBorder }
        // Rest: a visible hairline box (FilterField's rest language) when
        // standalone; clear inside grouped cells, which box the field
        // themselves.
        return idleBorder ? Color(nsColor: .separatorColor) : .clear
    }
}

extension View {
    /// Applies sheet/form field chrome; see `FormFieldChrome`.
    func formFieldChrome(isFocused: FocusState<Bool>.Binding, idleBorder: Bool = true) -> some View {
        modifier(FormFieldChrome(isFocused: isFocused, idleBorder: idleBorder))
    }
}

/// Field chrome that owns its focus, for dynamic rows inside `ForEach`
/// where a sheet-level `FocusState` can't tell which row is focused.
struct OwnFocusField<Field: View>: View {
    @FocusState private var isFocused: Bool
    var idleBorder = true
    @ViewBuilder let field: (FocusState<Bool>.Binding) -> Field

    var body: some View {
        field($isFocused)
            .formFieldChrome(isFocused: $isFocused, idleBorder: idleBorder)
    }
}

/// A small dropdown-style picker drawn entirely in SwiftUI.
/// Use for a small number of text options where a native pop-up button would
/// otherwise render as a white block off-screen.
struct OptionsPicker<Option: Hashable & Sendable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    @State private var isHovering = false

    init(
        _ title: String,
        selection: Binding<Option>,
        options: [Option],
        label: @escaping (Option) -> String
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if selection == option {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                pickerChrome
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .clickCursor()
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(isHovering ? AppColor.hoverBackground : Color.clear)
                .frame(height: AppSize.refreshControlHeight)
                .allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
        .help(title)
    }

    private var pickerChrome: some View {
        pickerLabelContent
            .foregroundStyle(.primary)
            .background(AppColor.pillBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .contentShape(Rectangle())
    }

    private var pickerLabelContent: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text(label(selection))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption)
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.mini)
        .frame(height: AppSize.refreshControlHeight)
    }
}

extension View {
    /// Applies `help` + `accessibilityLabel` only when text is present, so a
    /// `nil` help never blanks out the VoiceOver name with an empty string.
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text {
            self.help(text).accessibilityLabel(text)
        } else {
            self
        }
    }
}
