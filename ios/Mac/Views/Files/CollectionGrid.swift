import AppKit
import SwiftUI

/// What the grid asks of its screen. `open` is the primary action: double-click on a read-only cell, Return.
struct CollectionGridActions {
    var save: (DataRow, DataColumn, JSONValue) -> Void
    var edit: (DataRow, DataColumn) -> Void
    var open: (Set<DataRow.ID>) -> Void
    var copy: (Set<DataRow.ID>) -> Void
    var archive: (Set<DataRow.ID>) -> Void
    var delete: () -> Void
    var rowShown: (DataRow) -> Void
    /// A value typed in a cell that the column cannot take (a word in a number column).
    var reject: (String) -> Void
}

/// The rows of a collection in an AppKit table. SwiftUI's `Table` measured every row scrolled into view through a
/// hosting view per cell (automatic row heights) and diffed the whole collection on each page, which stalled long
/// collections. Here rows have a fixed height, a new page only adds rows, and each row draws its cells in a single
/// view: AppKit revisits every view and layer of the table at each scroll step, so a view per cell was as slow.
struct CollectionGrid: NSViewRepresentable {
    let columns: [DataColumn]
    let titleColumn: String?
    let rows: [DataRow]
    @Binding var selection: Set<DataRow.ID>
    @Binding var sort: String?
    let actions: CollectionGridActions

    func makeCoordinator() -> CollectionGridCoordinator { CollectionGridCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = CollectionGridTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 27 - table.intercellSpacing.height
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        context.coordinator.attach(table)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        context.coordinator.update(self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// The columns, shared by the coordinator and the row views that draw them.
@MainActor
private final class GridSchema {
    var columnsByName: [String: DataColumn] = [:]
    var titleColumn: String?
}

@MainActor
final class CollectionGridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    private struct Editing {
        let row: DataRow
        let column: DataColumn
        let text: String
        weak var cells: GridCellsView?
        var cancelled = false
    }

    private var grid: CollectionGrid?
    private weak var table: CollectionGridTableView?
    private let schema = GridSchema()
    private var rows: [DataRow] = []
    private var rowIndex: [String: Int] = [:]
    private var columns: [DataColumn] = []
    /// Set while the grid applies SwiftUI's state, so the table's own callbacks do not write it back mid-update.
    private var syncing = false
    private var editing: Editing?
    private var popover: NSPopover?

    private static let rowID = NSUserInterfaceItemIdentifier("row")

    func attach(_ table: CollectionGridTableView) {
        self.table = table
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.onPrimary = { [weak self] in self?.openSelection() }
        table.onDelete = { [weak self] in self?.grid?.actions.delete() }
    }

    func update(_ grid: CollectionGrid) {
        self.grid = grid
        guard let table else { return }
        syncing = true
        defer { syncing = false }
        if grid.columns != columns || grid.titleColumn != schema.titleColumn {
            columns = grid.columns
            schema.titleColumn = grid.titleColumn
            schema.columnsByName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            rebuildColumns(table)
            rows = grid.rows
            reindex(from: 0)
            table.reloadData()
        } else {
            apply(grid.rows, to: table)
        }
        syncSort(table)
        syncSelection(table)
    }

    // MARK: Updates

    private func rebuildColumns(_ table: NSTableView) {
        for column in table.tableColumns { table.removeTableColumn(column) }
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.name))
            tableColumn.title = column.label
            tableColumn.headerCell.alignment = column.isNumeric ? .right : .left
            tableColumn.minWidth = minWidth(column)
            tableColumn.width = idealWidth(column)
            tableColumn.maxWidth = 2_000
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.name, ascending: true)
            table.addTableColumn(tableColumn)
        }
    }

    /// A page appended at the end only adds rows; otherwise only rows that have a view are redrawn, the others are
    /// drawn from the new values when they scroll into view.
    private func apply(_ new: [DataRow], to table: NSTableView) {
        let old = rows
        let unchanged = new.count == old.count
            && new.withUnsafeBufferPointer { $0.baseAddress } == old.withUnsafeBufferPointer { $0.baseAddress }
        guard !unchanged else { return }
        rows = new
        guard new.count >= old.count, zip(old, new).allSatisfy({ $0.id == $1.id }) else {
            reindex(from: 0)
            table.reloadData()
            return
        }
        reindex(from: old.count)
        if new.count > old.count { table.noteNumberOfRowsChanged() }
        table.enumerateAvailableRowViews { view, row in
            guard row < old.count, old[row] != new[row], new[row].id != editing?.row.id else { return }
            (view as? GridRowView)?.cells.row = new[row]
        }
    }

    private func reindex(from start: Int) {
        if start == 0 { rowIndex = [:] }
        for index in start..<rows.count where rowIndex[rows[index].id] == nil {
            rowIndex[rows[index].id] = index
        }
    }

    private func syncSelection(_ table: NSTableView) {
        guard let wanted = grid?.selection, wanted != selectedIDs(table) else { return }
        let indexes = IndexSet(wanted.compactMap { rowIndex[$0] })
        guard indexes != table.selectedRowIndexes else { return }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        if indexes.count == 1, let index = indexes.first { table.scrollRowToVisible(index) }
    }

    private func syncSort(_ table: NSTableView) {
        let wanted = grid?.sort.flatMap(Self.descriptor)
        let current = table.sortDescriptors.first
        guard wanted?.key != current?.key || wanted?.ascending != current?.ascending || table.sortDescriptors.count > 1 else { return }
        table.sortDescriptors = wanted.map { [$0] } ?? []
    }

    private static func descriptor(_ sort: String) -> NSSortDescriptor? {
        let parts = sort.split(separator: ":")
        guard let name = parts.first else { return nil }
        return NSSortDescriptor(key: String(name), ascending: !(parts.count > 1 && parts[1] == "desc"))
    }

    private func selectedIDs(_ table: NSTableView) -> Set<DataRow.ID> {
        Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
    }

    private func redrawRows() {
        table?.enumerateAvailableRowViews { view, _ in (view as? GridRowView)?.cells.needsDisplay = true }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// No cell views: the row view draws its cells.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowID, owner: nil) as? GridRowView ?? {
            let view = GridRowView(schema: schema)
            view.identifier = Self.rowID
            view.cells.onToggle = { [weak self] row, column in
                self?.grid?.actions.save(row, column, .bool(!(row[column.name].bool ?? false)))
            }
            return view
        }()
        view.cells.row = row < rows.count ? rows[row] : nil
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard row < rows.count else { return }
        let item = rows[row]
        // Paging changes the store's rows: not from inside the table's layout pass.
        Task { @MainActor [weak self] in self?.grid?.actions.rowShown(item) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let table else { return }
        let ids = selectedIDs(table)
        if ids != grid?.selection { grid?.selection = ids }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !syncing, let first = tableView.sortDescriptors.first, let key = first.key else { return }
        grid?.sort = "\(key):\(first.ascending ? "asc" : "desc")"
    }

    func tableViewColumnDidResize(_ notification: Notification) { redrawRows() }

    func tableViewColumnDidMove(_ notification: Notification) { redrawRows() }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < rows.count else { return }
        let item = rows[row]
        let columnIndex = sender.clickedColumn
        guard columnIndex >= 0, let column = schema.columnsByName[sender.tableColumns[columnIndex].identifier.rawValue], !column.isComputed else {
            grid?.actions.open([item.id])
            return
        }
        switch column.type {
        case .text, .url, .number, .money, .percent: beginEditing(row: row, item: item, column: column)
        case .bool: break
        case .select: showOptions(row: row, item: item, column: column)
        default: grid?.actions.edit(item, column)
        }
    }

    private func openSelection() {
        guard let table else { return }
        let ids = selectedIDs(table)
        if !ids.isEmpty { grid?.actions.open(ids) }
    }

    private func showOptions(row: Int, item: DataRow, column: DataColumn) {
        guard let cells = (table?.rowView(atRow: row, makeIfNecessary: true) as? GridRowView)?.cells,
              let frame = cells.frame(of: column.name) else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: GridOptionList(column: column, selected: item[column.name].string) { [weak self, weak popover] value in
            popover?.close()
            self?.grid?.actions.save(item, column, value)
        })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: frame, of: cells, preferredEdge: .maxY)
        self.popover = popover
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        let clicked = rows[table.clickedRow].id
        let selected = selectedIDs(table)
        let ids = selected.contains(clicked) ? selected : [clicked]
        if ids.count == 1 { menu.addItem(menuItem(String(localized: "Show Detail"), #selector(showDetail(_:)), ids)) }
        menu.addItem(menuItem(String(localized: "Copy"), #selector(copyRows(_:)), ids))
        menu.addItem(.separator())
        menu.addItem(menuItem(ids.count > 1 ? String(localized: "Archive \(ids.count) Items…") : String(localized: "Archive…"), #selector(archiveRows(_:)), ids))
    }

    private func menuItem(_ title: String, _ action: Selector, _ ids: Set<DataRow.ID>) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = ids
        return item
    }

    @objc private func showDetail(_ sender: NSMenuItem) {
        if let ids = sender.representedObject as? Set<DataRow.ID> { grid?.actions.open(ids) }
    }

    @objc private func copyRows(_ sender: NSMenuItem) {
        if let ids = sender.representedObject as? Set<DataRow.ID> { grid?.actions.copy(ids) }
    }

    @objc private func archiveRows(_ sender: NSMenuItem) {
        if let ids = sender.representedObject as? Set<DataRow.ID> { grid?.actions.archive(ids) }
    }

    // MARK: Inline editing

    private func beginEditing(row: Int, item: DataRow, column: DataColumn) {
        guard let table, let cells = (table.rowView(atRow: row, makeIfNecessary: true) as? GridRowView)?.cells else { return }
        let text = Self.editableText(item[column.name], column)
        guard let field = cells.beginEditing(column, text: text, delegate: self) else { return }
        editing = Editing(row: item, column: column, text: text, cells: cells)
        table.window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), editing != nil else { return false }
        editing?.cancelled = true
        table?.window?.makeFirstResponder(table)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let editing else { return }
        self.editing = nil
        let text = field.stringValue
        editing.cells?.endEditing()
        let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        if editing.cancelled || movement == .return { table?.window?.makeFirstResponder(table) }
        guard !editing.cancelled, text != editing.text else { return }
        if let value = Self.parse(text, editing.column) {
            grid?.actions.save(editing.row, editing.column, value)
        } else {
            grid?.actions.reject(String(localized: "“\(text.trimmingCharacters(in: .whitespaces))” isn't a number: \(editing.column.label) keeps its value."))
        }
    }

    private static func editableText(_ value: JSONValue, _ column: DataColumn) -> String {
        switch column.type {
        case .money: value.double.map { ValueFormat.money($0) } ?? ""
        case .percent: value.double.map { ValueFormat.number($0 * 100) + " %" } ?? ""
        case .number: value.double.map(ValueFormat.number) ?? ""
        default: value.string ?? ""
        }
    }

    /// The value of the text typed in a cell of `column`; nil when it is not one (a word in a number column).
    private static func parse(_ text: String, _ column: DataColumn) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch column.type {
        case .number, .money, .percent:
            if trimmed.isEmpty { return .null }
            let digits = trimmed.replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: ",", with: ".")
            guard let number = Double(digits) else { return nil }
            return .number(column.type == .percent ? number / 100 : number)
        default:
            return trimmed.isEmpty ? .null : .string(trimmed)
        }
    }

    // MARK: Columns

    private func minWidth(_ column: DataColumn) -> CGFloat {
        column.name == schema.titleColumn ? 160 : column.isNumeric || column.type == .bool ? 70 : 90
    }

    private func idealWidth(_ column: DataColumn) -> CGFloat {
        if column.name == schema.titleColumn { return 260 }
        switch column.type {
        case .bool: return 70
        case .money, .number, .percent, .date: return 110
        case .longtext: return 260
        default: return 150
        }
    }
}

private extension DataColumn {
    var isNumeric: Bool { [.money, .number, .percent].contains(type) }
}

final class CollectionGridTableView: NSTableView {
    var onPrimary: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        guard plain, selectedRow >= 0 else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: onPrimary?()
        case 51, 117: onDelete?()
        default: super.keyDown(with: event)
        }
    }

    @objc func delete(_ sender: Any?) { onDelete?() }
}

private final class GridRowView: NSTableRowView {
    let cells: GridCellsView

    init(schema: GridSchema) {
        cells = GridCellsView(schema: schema)
        super.init(frame: .zero)
        cells.autoresizingMask = [.width, .height]
        addSubview(cells)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { cells.needsDisplay = true } }
    }

    override var isEmphasized: Bool {
        didSet { if isEmphasized != oldValue { cells.needsDisplay = true } }
    }
}

/// The cells of one row, drawn like the SwiftUI cells they replace: plain text, a checkbox symbol for booleans and
/// the colored chip of `OptionChip` for selects. A click on a checkbox toggles it without selecting the row.
private final class GridCellsView: NSView {
    var row: DataRow? {
        didSet {
            // A recycled row view must not carry an edit over to another row: ending it saves it.
            if row?.id != oldValue?.id, let editor {
                if editor.currentEditor() != nil { window?.makeFirstResponder(nil) }
                endEditing()
            }
            if row != oldValue { needsDisplay = true }
        }
    }
    var onToggle: ((DataRow, DataColumn) -> Void)?
    private let schema: GridSchema
    private var editor: NSTextField?
    private var editingColumn: String?

    private static let body = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let title = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    private static let chip = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold)
    private static let lineHeight = ceil(body.ascender - body.descender + body.leading)
    private static let accent = NSColor(Color.accent)
    private static let paragraphs: [NSTextAlignment: NSParagraphStyle] = [.left: paragraph(.left), .right: paragraph(.right)]

    init(schema: GridSchema) {
        self.schema = schema
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var rowView: NSTableRowView? { superview as? NSTableRowView }
    private var table: NSTableView? { rowView?.superview as? NSTableView }

    /// Visible columns with their cell frame in this view, in display order.
    private func cellFrames() -> [(column: DataColumn, frame: NSRect)] {
        guard let table, let rowView else { return [] }
        let index = table.row(for: rowView)
        guard index >= 0 else { return [] }
        return table.tableColumns.enumerated().compactMap { offset, tableColumn in
            guard !tableColumn.isHidden, let column = schema.columnsByName[tableColumn.identifier.rawValue] else { return nil }
            let frame = convert(table.frameOfCell(atColumn: offset, row: index), from: table)
            return (column, NSRect(x: frame.minX, y: 0, width: frame.width, height: bounds.height))
        }
    }

    func frame(of column: String) -> NSRect? {
        cellFrames().first { $0.column.name == column }?.frame
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let emphasized = rowView?.interiorBackgroundStyle == .emphasized
        for (column, frame) in cellFrames() where frame.intersects(dirtyRect) && column.name != editingColumn {
            let value = row[column.name]
            if !column.isComputed, column.type == .bool {
                drawCheckbox(on: value.bool ?? false, in: frame, emphasized: emphasized)
            } else if !column.isComputed, column.type == .select {
                if let option = ValueFormat.option(value.string, in: column) {
                    drawChip(option, in: frame)
                } else {
                    drawText("—", in: frame, font: Self.body, color: textColor(.tertiaryLabelColor, emphasized), alignment: .left)
                }
            } else {
                let color: NSColor = value.isNull ? .tertiaryLabelColor : column.isComputed ? .secondaryLabelColor : .labelColor
                drawText(ValueFormat.text(value, column: column, refTitle: row.refs?[column.name]), in: frame,
                         font: column.name == schema.titleColumn ? Self.title : Self.body,
                         color: textColor(color, emphasized), alignment: column.isNumeric ? .right : .left)
            }
        }
    }

    private func textColor(_ color: NSColor, _ emphasized: Bool) -> NSColor {
        guard emphasized else { return color }
        let alpha: CGFloat = color == .labelColor ? 1 : color == .secondaryLabelColor ? 0.75 : 0.5
        return NSColor.alternateSelectedControlTextColor.withAlphaComponent(alpha)
    }

    private func drawText(_ text: String, in frame: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let rect = NSRect(x: frame.minX, y: floor((frame.height - Self.lineHeight) / 2), width: frame.width, height: Self.lineHeight)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: Self.paragraphs[alignment] ?? .default])
    }

    private func drawCheckbox(on: Bool, in frame: NSRect, emphasized: Bool) {
        let color = emphasized ? NSColor.alternateSelectedControlTextColor : on ? Self.accent : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: on ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: frame.minX, y: floor((frame.height - size.height) / 2), width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawChip(_ option: DataOption, in frame: NSRect) {
        let color = NSColor(ValueFormat.color(for: option))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.chip,
            .foregroundColor: color.blended(withFraction: 0.35, of: .labelColor) ?? color,
        ]
        let text = option.display as NSString
        let textSize = text.size(withAttributes: attributes)
        let height = ceil(textSize.height) + 6
        let rect = NSRect(x: frame.minX, y: floor((frame.height - height) / 2), width: min(frame.width, ceil(textSize.width) + 25), height: height)
        color.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 7, y: rect.midY - 3, width: 6, height: 6)).fill()
        text.draw(with: NSRect(x: rect.minX + 18, y: rect.minY + 3, width: max(0, rect.width - 25), height: ceil(textSize.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    // MARK: Editing

    func beginEditing(_ column: DataColumn, text: String, delegate: NSTextFieldDelegate) -> NSTextField? {
        guard let frame = frame(of: column.name) else { return nil }
        endEditing()
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.font = column.name == schema.titleColumn ? Self.title : Self.body
        field.alignment = column.isNumeric ? .right : .left
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.delegate = delegate
        // The field's cell pads its text by 2 pt: keep the text where it was drawn.
        field.frame = NSRect(x: frame.minX - 2, y: floor((frame.height - Self.lineHeight) / 2) - 1, width: frame.width + 4, height: Self.lineHeight + 2)
        addSubview(field)
        editor = field
        editingColumn = column.name
        needsDisplay = true
        return field
    }

    func endEditing() {
        guard let editor else { return }
        editor.delegate = nil
        editor.removeFromSuperview()
        self.editor = nil
        editingColumn = nil
        needsDisplay = true
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let row, let cell = cellFrames().first(where: { $0.frame.contains(point) }), !cell.column.isComputed, cell.column.type == .bool {
            onToggle?(row, cell.column)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        guard let row else { return [] }
        var children: [Any] = cellFrames().map { column, frame in
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(frame)
            element.setAccessibilityLabel(column.label)
            let value = row[column.name]
            if !column.isComputed, column.type == .bool {
                element.setAccessibilityRole(.checkBox)
                element.setAccessibilityValue(value.bool == true ? 1 : 0)
            } else {
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityValue(ValueFormat.text(value, column: column, refTitle: row.refs?[column.name]))
            }
            return element
        }
        if let editor { children.append(editor) }
        return children
    }
}

/// Options of a select cell, in the popover opened by a double-click.
private struct GridOptionList: View {
    let column: DataColumn
    let selected: String?
    let choose: (JSONValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(column.options ?? []) { option in
                Button { choose(.string(option.value)) } label: {
                    HStack {
                        OptionChip(option: option, compact: true)
                        Spacer(minLength: 12)
                        if option.value == selected { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
            Divider()
            Button("None") { choose(.null) }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
        }
        .padding(10)
        .frame(minWidth: 180)
    }
}
