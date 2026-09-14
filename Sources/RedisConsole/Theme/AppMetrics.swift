import Foundation
import SwiftUI

/// Standard animation durations.
enum AppAnimation {
    /// Quick hover/press feedback used across buttons, rows, and menus.
    static let quick: Animation = .easeOut(duration: 0.12)
}

/// Standard spacing, corner radius, and size constants.
///
/// Centralizing these values removes magic numbers and keeps the UI
/// visually consistent.
enum AppSpacing {
    static let xxSmall: CGFloat = 2
    static let xSmall: CGFloat = 4
    /// Compact 6pt step for dense rows (refresh bars, table rows, pills).
    /// Replaces the `small - xxSmall` arithmetic scattered across views.
    static let mini: CGFloat = 6
    static let small: CGFloat = 8
    /// Compact 10pt step. Replaces `medium - xxSmall`.
    static let compact: CGFloat = 10
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 20
}

enum AppRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 6
    static let large: CGFloat = 8
    static let pill: CGFloat = 9999
}

enum AppSize {
    static let productionConfirmWidth: CGFloat = 320
    static let ttlEditorWidth: CGFloat = 260
    static let formFieldWidth: CGFloat = 80
    /// Fixed width for leading form labels (e.g. Library / Function / Mode rows in dialogs)
    /// so their values stay left-aligned across rows.
    static let formLabelWidth: CGFloat = 68
    /// Compact width for short leading labels (e.g. Key / Type / Value rows in Add New Key sheet).
    /// Sized to fit the longest label ("Value") with a small margin.
    static let formLabelWidthCompact: CGFloat = 40
    /// Unified height for bottom status bars, matching `refreshControlHeight`
    /// so text-only and control footers stay the same size.
    static let footerHeight: CGFloat = 28
    /// Unified minimum height for panel toolbars/headers (Keys, Shell, Profiler, Slow Log, Analysis, Server Info).
    /// Applied as a `minHeight` so headers stay consistent while still growing to fit taller content.
    static let toolbarHeight: CGFloat = 44
    static let refreshControlHeight: CGFloat = 28
    static let refreshButtonWidth: CGFloat = 32
    static let refreshSeparatorHeight: CGFloat = 16
    /// Unified width for the small type/engine badge in key and library rows.
    /// Sized to fit the longest key type ("String"); "ZSet" replaced "Sorted Set"
    /// so 64pt is no longer needed.
    static let typeBadgeWidth: CGFloat = 44
    /// Horizontal inset of the native sidebar selection rect, mirrored by
    /// `sidebarHoverWash` so hover matches selection geometry.
    static let sidebarSelectionInset: CGFloat = 10
    /// Width of the trailing icon buttons inside `FilterField`.
    /// The buttons stretch to the field height via overlay, so no
    /// hardcoded field height lives here.
    static let filterFieldIconWidth: CGFloat = 22
    /// Fixed width of the settings sidebar column.
    static let settingsSidebarWidth: CGFloat = 215
    /// Minimum width of the settings detail column.
    static let settingsDetailMinimumWidth: CGFloat = 420
    /// Fixed width of the flat/grouped display toggle in list headers.
    static let binaryToggleWidth: CGFloat = 64
    /// Width of the TTL seconds field in the TTL editor popover.
    static let ttlInputWidth: CGFloat = 140
    /// Width of the leading key column in the generic key-detail fallback table.
    static let detailKeyColumnWidth: CGFloat = 100
    /// Width of the Add New Key sheet.
    static let addKeySheetWidth: CGFloat = 560
    /// Width of the type picker inside the Add New Key sheet.
    static let addKeyTypePickerWidth: CGFloat = 260
    /// Width of the disclosure chevron in namespace tree rows.
    static let namespaceChevronWidth: CGFloat = 12
    /// Width of a table Actions column with a single button.
    static let tableActionsWidthSingle: CGFloat = 60
    /// Width of a table Actions column with edit + delete buttons.
    static let tableActionsWidthDouble: CGFloat = 80
    /// Height of a table header cell, matching `NSTableHeaderView` metrics.
    static let tableHeaderHeight: CGFloat = 28
    /// Diameter of a cluster topology node hit area.
    static let topologyNodeDiameter: CGFloat = 44
    /// Height of distribution bars in the analysis charts.
    static let barHeight: CGFloat = 16
    /// Minimum visible width of a distribution bar segment.
    static let barMinWidth: CGFloat = 4
}
