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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
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
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    init(_ placeholder: String, text: Binding<String>, onSearch: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.onSearch = onSearch
    }

    /// Right-side icon slots: clear button (when text is non-empty) + search/focus button.
    /// Both slots are 22pt buttons so server-side and local-filter variants share geometry.
    private var showsClearButton: Bool { !text.isEmpty }

    private var borderColor: Color {
        if isFocused {
            return .accentColor
        }
        return isHovering ? AppColor.subtleBorder : Color(nsColor: .separatorColor)
    }

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                // Same font + vertical padding as Primary/SecondaryButtonStyle
                // labels, so the field always matches same-row button height
                // without a hardcoded frame.
                .font(.system(.body, design: .default))
                .focused($isFocused)
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
                    isFocused = true
                }
            }
        }
        .padding(.leading, AppSpacing.small)
        .padding(.trailing, AppSpacing.small)
        .padding(.vertical, AppSpacing.mini)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(isHovering && !isFocused ? AppColor.hoverBackground : Color.clear)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
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
            .background(
                isHovering ? AppColor.iconHoverBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
            )
            .onHover { isHovering = $0 }
            .animation(AppAnimation.quick, value: isHovering)
            .help(helpText)
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
            .background(.background.secondary)
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

/// Clickable sort control for a key-detail table column header, styled after
/// Sequel Ace: it draws the standard AppKit sort indicator and handles the
/// click itself. The underlying column is intentionally left non-sortable
/// because macOS 27 draws an extra separator in front of the active sort
/// column; this overlay reproduces the indicator without that artifact.
struct HeaderSortControl: View {
    let ascending: Bool
    /// Total width of the column's header cell (leading inset + column width
    /// + intercell gap), matching `NSTableHeaderView` metrics.
    let headerWidth: CGFloat
    var disabled: Bool = false
    var helpText = "Sort"
    let onToggle: () -> Void

    private static let headerHeight: CGFloat = AppSize.tableHeaderHeight
    private static let indicatorTrailingInset: CGFloat = AppSpacing.small
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            Color.clear
                .frame(width: headerWidth, height: Self.headerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .background(
            isHovering && !disabled ? AppColor.hoverBackground : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isFocused ? 1.5 : 0)
        )
        .overlay(alignment: .trailing) {
            Image(nsImage: Self.sortIndicatorImage(ascending: ascending))
                .foregroundStyle(.secondary)
                .opacity(disabled ? 0.35 : 1)
                .padding(.trailing, Self.indicatorTrailingInset)
        }
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private static func sortIndicatorImage(ascending: Bool) -> NSImage {
        let name: NSImage.Name = ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
        return NSImage(named: name) ?? NSImage(size: NSSize(width: 8, height: 8))
    }
}
