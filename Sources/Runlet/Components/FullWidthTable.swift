import AppKit
import SwiftUI

// MARK: - Full-Width Table

/// Multi-column data table backed by AppKit — an `NSTableView` in the
/// `.fullWidth` style inside a bare `NSScrollView` — instead of SwiftUI's
/// `Table`.
///
/// SwiftUI's table keeps its rows inside the modern inset style's side
/// gutters, so hover, selection, and separators stop short of the panel edges.
/// An AppKit table draws the row chrome edge to edge, matching the
/// `fullWidthListRow` lists elsewhere in the app, while cell content is still
/// SwiftUI: each cell hosts its content in an `NSHostingView` that fills the
/// cell, and rows size themselves from the hosted content.
///
/// The chrome is painted by `FullWidthRowView` with the app's own selection
/// rule: the vivid `selectedContentBackgroundColor` whenever the window is
/// key, dimming to the unemphasized gray only when the window itself is
/// inactive. Selected rows publish `listRowIsSelected` into the cell
/// environment, so cell content flips to the on-selection foreground with
/// `selectionForeground(_:)`, like native emphasized rows. Rows keep the
/// system's alternating content backgrounds, so the table reads as a data grid
/// rather than a stack of list rows.
///
/// The flexible column (the one whose `Column.width` is `nil`) absorbs
/// whatever width the fixed columns leave over, so the table always fills the
/// panel; fixed columns stay user-resizable within their bounds.
struct FullWidthTable<Row: Identifiable>: View {
    /// One column definition. `width == nil` marks the table's single flexible
    /// column.
    struct Column {
        /// Sort control drawn inside this column's header cell.
        struct Sort {
            var ascending: Bool
            var disabled = false
            var help: String?
            let onToggle: () -> Void
        }

        let title: String
        var width: CGFloat?
        var minWidth: CGFloat = 44
        var maxWidth: CGFloat = 4000
        var resizable = true
        var sort: Sort?
        let content: (Row) -> AnyView

        init(
            title: String,
            width: CGFloat? = nil,
            minWidth: CGFloat = 44,
            maxWidth: CGFloat = 4000,
            resizable: Bool = true,
            sort: Sort? = nil,
            content: @escaping (Row) -> AnyView
        ) {
            self.title = title
            self.width = width
            self.minWidth = minWidth
            self.maxWidth = maxWidth
            self.resizable = resizable
            self.sort = sort
            self.content = content
        }
    }

    let rows: [Row]
    let columns: [Column]
    @Binding var selection: Set<Row.ID>
    /// Minimum row height; rows grow past it to fit two-line cell content.
    var minRowHeight: CGFloat = AppSize.tableRowHeight
    /// Leading/trailing padding inside each cell. The row chrome around it
    /// still runs edge to edge.
    var cellPadding: CGFloat = AppSpacing.small
    /// Double-click handler, receiving the clicked row and column index.
    var onDoubleClick: ((Row, Int) -> Void)?
    /// Context menu for a right-clicked row. Right-clicking an unselected row
    /// selects it first, like a native table.
    var contextMenu: ((Row) -> NSMenu?)?

    var body: some View {
        GeometryReader { proxy in
            FullWidthTableRepresentable(parent: self, availableWidth: proxy.size.width)
        }
    }
}

// MARK: - Representable

private struct FullWidthTableRepresentable<Row: Identifiable>: NSViewRepresentable {
    let parent: FullWidthTable<Row>
    let availableWidth: CGFloat

    func makeCoordinator() -> FullWidthTableCoordinator {
        let coordinator = FullWidthTableCoordinator()
        coordinator.apply(parent: parent)
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = FullWidthTableView()
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = parent.minRowHeight
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.backgroundColor = .controlBackgroundColor
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.headerView = FullWidthHeaderView(
            frame: NSRect(x: 0, y: 0, width: 0, height: AppSize.tableHeaderHeight)
        )
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(FullWidthTableCoordinator.handleDoubleClick(_:))
        tableView.onLayoutChange = { [weak coordinator = context.coordinator] in
            coordinator?.sizeFlexibleColumn()
        }
        context.coordinator.attach(to: tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(parent: parent)
        context.coordinator.availableWidth = availableWidth
        context.coordinator.update()
    }
}

// MARK: - Coordinator

/// Data source, delegate, and menu target for `FullWidthTable`. The table's
/// generic row type is erased into the closures assigned by `apply(parent:)`,
/// so the ObjC-visible pieces stay non-generic.
final class FullWidthTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var rowCount: () -> Int = { 0 }
    var rowIDs: () -> [AnyHashable] = { [] }
    var columnDescriptors: () -> [FullWidthTableColumnDescriptor] = { [] }
    var sortActions: [(() -> Void)?] = []
    var cellContent: (Int, Int, Bool) -> AnyView = { _, _, _ in AnyView(EmptyView()) }
    var desiredSelection: () -> IndexSet = { IndexSet() }
    var selectionDidChange: (IndexSet) -> Void = { _ in }
    var contextMenuForRow: (Int) -> NSMenu? = { _ in nil }
    var doubleClick: (Int, Int) -> Void = { _, _ in }
    var availableWidth: CGFloat = 0

    private weak var tableView: FullWidthTableView?
    private let menuTarget = FullWidthTableMenuTarget()
    private var lastRowIDs: [AnyHashable] = []
    private var lastColumnSignature = ""
    private var isApplyingSelection = false
    private var isSizingFlexibleColumn = false

    func attach(to tableView: FullWidthTableView) {
        self.tableView = tableView
        tableView.contextMenuForRow = { [weak self] row in
            self?.menu(forRow: row)
        }
    }

    /// Re-assigns the closures that erase the generic row type.
    func apply<Row: Identifiable>(parent: FullWidthTable<Row>) {
        rowCount = { [rows = parent.rows] in rows.count }
        rowIDs = { [rows = parent.rows] in rows.map { AnyHashable($0.id) } }
        columnDescriptors = { [columns = parent.columns] in
            columns.map {
                FullWidthTableColumnDescriptor(
                    title: $0.title,
                    width: $0.width,
                    minWidth: $0.minWidth,
                    maxWidth: $0.maxWidth,
                    resizable: $0.resizable,
                    sort: $0.sort.map {
                        FullWidthTableSortDescriptor(
                            ascending: $0.ascending,
                            disabled: $0.disabled,
                            help: $0.help
                        )
                    }
                )
            }
        }
        sortActions = parent.columns.map { $0.sort?.onToggle }
        let rows = parent.rows
        let columns = parent.columns
        let padding = parent.cellPadding
        let minRowHeight = parent.minRowHeight
        cellContent = { row, column, isSelected in
            guard rows.indices.contains(row), columns.indices.contains(column) else {
                return AnyView(EmptyView())
            }
            return AnyView(
                columns[column].content(rows[row])
                    .padding(.horizontal, padding)
                    .padding(.vertical, AppSpacing.mini)
                    .frame(maxWidth: .infinity, minHeight: minRowHeight, alignment: .leading)
                    .environment(\.listRowIsSelected, isSelected)
            )
        }
        desiredSelection = { [rows = parent.rows, selection = parent.$selection] in
            IndexSet(
                rows.enumerated().compactMap {
                    selection.wrappedValue.contains($0.element.id) ? $0.offset : nil
                }
            )
        }
        selectionDidChange = { [rows = parent.rows, selection = parent.$selection] indexes in
            let ids = indexes.compactMap { index in
                rows.indices.contains(index) ? rows[index].id : nil
            }
            let newValue = Set(ids)
            if selection.wrappedValue != newValue {
                selection.wrappedValue = newValue
            }
        }
        contextMenuForRow = { [rows = parent.rows, contextMenu = parent.contextMenu] row in
            guard rows.indices.contains(row) else { return nil }
            return contextMenu?(rows[row])
        }
        doubleClick = { [rows = parent.rows, onDoubleClick = parent.onDoubleClick] row, column in
            guard rows.indices.contains(row) else { return }
            onDoubleClick?(rows[row], column)
        }
    }

    func update() {
        guard let tableView else { return }
        configureColumns(in: tableView)
        applyHeaderState(in: tableView)
        let ids = rowIDs()
        if ids != lastRowIDs {
            lastRowIDs = ids
            tableView.reloadData()
        }
        applySelection(in: tableView)
        sizeFlexibleColumn()
        refreshVisibleCells(in: tableView)
    }

    /// Sizes the flexible column so the fixed columns and the table's width
    /// always add up to the panel width.
    func sizeFlexibleColumn() {
        guard let tableView, !isSizingFlexibleColumn else { return }
        let columns = tableView.tableColumns
        let descriptors = columnDescriptors()
        guard let flexibleIndex = descriptors.firstIndex(where: { $0.width == nil }),
            flexibleIndex < columns.count,
            availableWidth > 0
        else { return }
        isSizingFlexibleColumn = true
        defer { isSizingFlexibleColumn = false }
        let spacing = tableView.intercellSpacing.width * CGFloat(max(0, columns.count - 1))
        let fixedWidth = columns.enumerated()
            .filter { $0.offset != flexibleIndex }
            .reduce(CGFloat.zero) { $0 + $1.element.width }
        let width = max(columns[flexibleIndex].minWidth, availableWidth - fixedWidth - spacing)
        if abs(columns[flexibleIndex].width - width) > 0.5 {
            columns[flexibleIndex].width = width
        }
    }

    private func configureColumns(in tableView: NSTableView) {
        let descriptors = columnDescriptors()
        let signature = descriptors.map { descriptor in
            let width = descriptor.width.map(String.init) ?? "flexible"
            return "\(descriptor.title)|\(width)|\(descriptor.minWidth)|\(descriptor.maxWidth)|\(descriptor.resizable)"
        }.joined(separator: ";")
        guard signature != lastColumnSignature else { return }
        lastColumnSignature = signature
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        for (index, descriptor) in descriptors.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column-\(index)"))
            let cell = FullWidthHeaderCell()
            cell.stringValue = descriptor.title
            column.headerCell = cell
            column.width = descriptor.width ?? descriptor.minWidth
            column.minWidth = descriptor.minWidth
            column.maxWidth = descriptor.maxWidth
            column.resizingMask = descriptor.resizable ? .userResizingMask : []
            tableView.addTableColumn(column)
        }
    }

    /// Pushes the current sort state into the header, so the indicator, hover
    /// target, and tooltip follow state that changes without a column rebuild
    /// (e.g. sorting disabled while filtering).
    private func applyHeaderState(in tableView: NSTableView) {
        let descriptors = columnDescriptors()
        let header = tableView.headerView as? FullWidthHeaderView
        for (index, column) in tableView.tableColumns.enumerated() where index < descriptors.count {
            guard let cell = column.headerCell as? FullWidthHeaderCell else { continue }
            let sort = descriptors[index].sort
            cell.isSortable = sort != nil
            cell.sortAscending = sort?.ascending ?? false
            cell.sortDisabled = sort?.disabled ?? false
            cell.isHovered = header?.hoveredColumn == index
        }
        var sortColumns: [Int: ColumnSortState] = [:]
        for (index, descriptor) in descriptors.enumerated() {
            guard let sort = descriptor.sort else { continue }
            sortColumns[index] = ColumnSortState(disabled: sort.disabled, help: sort.help)
        }
        header?.sortColumns = sortColumns
        header?.onToggleSort = { [weak self] index in
            guard let self, self.sortActions.indices.contains(index) else { return }
            self.sortActions[index]?()
        }
        header?.invalidateCells()
    }

    private func applySelection(in tableView: NSTableView) {
        let desired = desiredSelection()
        guard desired != tableView.selectedRowIndexes else { return }
        isApplyingSelection = true
        tableView.selectRowIndexes(desired, byExtendingSelection: false)
        isApplyingSelection = false
        refreshVisibleCells(in: tableView)
    }

    /// Re-renders the visible cells so content follows data and selection
    /// changes, and re-measures their rows for two-line growth or shrink.
    private func refreshVisibleCells(in tableView: NSTableView) {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        var touched = IndexSet()
        for row in visible.location..<(visible.location + visible.length) {
            let isSelected = tableView.selectedRowIndexes.contains(row)
            for column in 0..<tableView.numberOfColumns {
                guard
                    let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false)
                        as? FullWidthTableHostingCell
                else { continue }
                cell.hosting.rootView = cellContent(row, column, isSelected)
            }
            touched.insert(row)
        }
        tableView.noteHeightOfRows(withIndexesChanged: touched)
    }

    private func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let menu = contextMenuForRow(row) else { return nil }
        assignTarget(in: menu)
        return menu
    }

    private func assignTarget(in menu: NSMenu) {
        for item in menu.items {
            item.target = menuTarget
            if let submenu = item.submenu {
                assignTarget(in: submenu)
            }
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn)
        else { return nil }
        let reused =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
            as? FullWidthTableHostingCell
        let cell: FullWidthTableHostingCell
        if let reused {
            cell = reused
        } else {
            cell = FullWidthTableHostingCell()
            cell.identifier = tableColumn.identifier
        }
        cell.hosting.rootView = cellContent(row, columnIndex, tableView.selectedRowIndexes.contains(row))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FullWidthRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let tableView else { return }
        selectionDidChange(tableView.selectedRowIndexes)
        refreshVisibleCells(in: tableView)
    }

    @objc func handleDoubleClick(_ sender: Any?) {
        guard let tableView else { return }
        doubleClick(tableView.clickedRow, tableView.clickedColumn)
    }
}

// MARK: - Row Chrome

/// Row chrome for `FullWidthTable`: the system's alternating background, an
/// edge-to-edge hover wash, and the app's selection fill. Zebra rows already
/// delineate the rows, so no separator is painted on top of them.
final class FullWidthRowView: NSTableRowView {
    private var isHovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovering(false)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // AppKit sets `backgroundColor` per row for the alternating pattern.
        super.drawBackground(in: dirtyRect)
        guard isHovering, !isSelected else { return }
        NSColor(AppColor.hoverBackground).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color: NSColor =
            window?.isKeyWindow == true
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        bounds.fill()
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        needsDisplay = true
    }
}

// MARK: - Table View

/// `NSTableView` for `FullWidthTable`: right-clicks select the row under the
/// pointer and route through the context-menu hook, and every layout change
/// re-lets the flexible column resize.
final class FullWidthTableView: NSTableView {
    var contextMenuForRow: ((Int) -> NSMenu?)?
    var onLayoutChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayoutChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayoutChange?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let menu = contextMenuForRow?(row) else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menu
    }
}

// MARK: - Header

/// AppKit-facing sort state of one header column.
struct ColumnSortState {
    let disabled: Bool
    let help: String?
}

/// Header chrome for `FullWidthTable`: the gray bar, the hover wash and sort
/// indicator of sortable columns, and the hairline along the bottom edge.
///
/// The bar and hover washes are painted by the header cells rather than here:
/// the system header draws its own background over anything painted before
/// `super`, and the cells' frames tile the bar — including the intercell
/// spacing each absorbs — so a hover wash reaches the column separator exactly.
final class FullWidthHeaderView: NSTableHeaderView {
    var onToggleSort: ((Int) -> Void)?
    var sortColumns: [Int: ColumnSortState] = [:]
    private(set) var hoveredColumn = -1

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `mouseMoved` tracking areas only fire when the window accepts
        // mouse-moved events; without this the header never sees the pointer
        // and the sortable columns never light up.
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect,
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHoveredColumn(column(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredColumn(column(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredColumn(-1)
    }

    override func mouseDown(with event: NSEvent) {
        let column = self.column(at: convert(event.locationInWindow, from: nil))
        if let sort = sortColumns[column], !sort.disabled {
            onToggleSort?(column)
            return
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        let separatorY = isFlipped ? bounds.maxY - 1 : bounds.minY
        NSRect(x: bounds.minX, y: separatorY, width: bounds.width, height: 1).fill()
    }

    /// Re-reads the header cells, e.g. after the sort state changed without a
    /// column rebuild (sorting disabled while filtering).
    func invalidateCells() {
        needsDisplay = true
    }

    private func setHoveredColumn(_ column: Int) {
        let target = sortColumns[column] != nil ? column : -1
        guard target != hoveredColumn else { return }
        let previous = hoveredColumn
        hoveredColumn = target
        for index in [previous, target] where index >= 0 {
            cell(atColumn: index)?.isHovered = index == target
        }
        toolTip = target >= 0 ? sortColumns[target]?.help : nil
        needsDisplay = true
    }

    private func cell(atColumn index: Int) -> FullWidthHeaderCell? {
        guard let tableView, tableView.tableColumns.indices.contains(index) else { return nil }
        return tableView.tableColumns[index].headerCell as? FullWidthHeaderCell
    }
}

/// Flat header cell: no bar of its own — the table's content background shows
/// through — the title sits at the table's cell padding, and sortable columns
/// get a hover wash with the system sort indicator on the trailing edge.
final class FullWidthHeaderCell: NSTableHeaderCell {
    var isSortable = false
    var isHovered = false
    var sortAscending = false
    var sortDisabled = false

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawBackground(in: cellFrame)
        drawInterior(withFrame: cellFrame, in: controlView)
        drawSortIndicator(in: cellFrame)
        drawSeparator(after: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let size = title.size()
        let rect = NSRect(
            x: cellFrame.minX + AppSpacing.small,
            y: cellFrame.midY - size.height / 2,
            width: max(0, cellFrame.width - AppSpacing.small * 2),
            height: size.height
        )
        title.draw(in: rect)
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {}

    private func drawBackground(in cellFrame: NSRect) {
        guard isHovered, isSortable, !sortDisabled else { return }
        NSColor(AppColor.hoverBackground).setFill()
        cellFrame.fill()
    }

    private func drawSortIndicator(in cellFrame: NSRect) {
        guard isSortable else { return }
        let name: NSImage.Name = sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
        guard let image = NSImage(named: name) else { return }
        let size = image.size
        let rect = NSRect(
            x: cellFrame.maxX - AppSpacing.large - size.width,
            y: cellFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: sortDisabled ? 0.35 : 1)
    }

    /// Column separators, like the system header's: a hairline on the trailing
    /// edge between columns, skipped at the table's right edge and inset from
    /// the bar's top and bottom so it reads as a light rule.
    private func drawSeparator(after cellFrame: NSRect, in controlView: NSView) {
        guard cellFrame.maxX < controlView.bounds.maxX - 0.5 else { return }
        NSColor.separatorColor.setFill()
        NSRect(
            x: cellFrame.maxX - 1,
            y: cellFrame.minY + AppSpacing.xSmall,
            width: 1,
            height: max(0, cellFrame.height - AppSpacing.xSmall * 2)
        ).fill()
    }
}

// MARK: - Hosting Cell

/// Table cell that hosts a SwiftUI view filling the cell, so the row chrome
/// around it stays edge to edge while automatic row heights read the hosted
/// content's fitting height.
final class FullWidthTableHostingCell: NSTableCellView {
    let hosting = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

// MARK: - Column Descriptor

/// AppKit-facing description of one `FullWidthTable.Column`.
struct FullWidthTableColumnDescriptor {
    let title: String
    let width: CGFloat?
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let resizable: Bool
    let sort: FullWidthTableSortDescriptor?
}

/// Sort state of one column, handed to the header cell and view.
struct FullWidthTableSortDescriptor {
    let ascending: Bool
    let disabled: Bool
    let help: String?
}

// MARK: - Context Menu

/// Target for menus built with `NSMenuItem(_:handler:)`; the handler rides in
/// `representedObject` and runs when the item is picked.
final class FullWidthTableMenuTarget: NSObject {
    @objc func perform(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}

extension NSMenuItem {
    /// Menu item that runs a closure when picked, for `FullWidthTable`
    /// context menus. `FullWidthTable` installs the target that performs it.
    convenience init(_ title: String, handler: @escaping () -> Void) {
        self.init(
            title: title,
            action: #selector(FullWidthTableMenuTarget.perform(_:)),
            keyEquivalent: ""
        )
        representedObject = handler
    }
}
