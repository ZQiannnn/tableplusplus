import SwiftUI
import AppKit

/// Row context-menu actions routed back to the owning view (which holds the SessionStore).
enum GridCellAction {
    case copyCell, copyRowJSON, copyRowInsert, setNull, setEmpty, filterByValue
    case insertRow, duplicateRow
}

/// AppKit NSTableView wrapped in SwiftUI. Column resize is hardware-smooth.
/// Used by TableViewerView in place of pure-SwiftUI DataGrid.
struct AppKitDataGrid: NSViewRepresentable {
    let columns: [String]
    let rows: [DriverRow]
    var dataKey: String = ""
    /// Reload triggers that should also drop selection (table/page/sort change). Empty ⇒ always reset on reload.
    var selectionKey: String = ""
    var sortColumn: String? = nil
    var sortAscending: Bool = true
    var onSelect: ((Int?) -> Void)? = nil
    var onHeaderClick: ((String) -> Void)? = nil
    var editable: Bool = false
    /// Grid-row index at/after which rows are uncommitted insert drafts (green highlight, editable).
    var insertRowStart: Int = .max
    /// Columns a user must not hand-fill in an insert draft (auto-increment / generated / BIT).
    var nonEditableInsertColumns: Set<String> = []
    /// Grid-row indices marked for deletion (red highlight, not editable).
    var deletedRows: Set<Int> = []
    /// Focus request: when `focusToken` changes, scroll to + select `focusRow`.
    var focusToken: Int = 0
    var focusRow: Int? = nil
    /// Outer nil ⇒ cell not edited; inner nil ⇒ edited to NULL.
    var editOverride: ((Int, String) -> String??)? = nil
    var onEditCommit: ((Int, String, String?) -> Void)? = nil
    /// Row context-menu action. nil ⇒ no context menu on this grid.
    var onCellAction: ((GridCellAction, Int, String) -> Void)? = nil
    /// Delete the given grid-row indices (single or multi). Caller resolves existing vs draft rows.
    var onDeleteRows: ((IndexSet) -> Void)? = nil
    var allowsMultipleSelection: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TPPTableView()
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.cellClicked(_:))
        table.doubleAction = #selector(Coordinator.cellDoubleClicked(_:))
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []   // vertical grid lines drawn by the row canvas (only for visible columns)
        table.gridColor = NSColor(srgbRed: 58/255, green: 58/255, blue: 58/255, alpha: 1)
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 26
        table.headerView = TPPHeaderView()
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        // Colors sampled from TablePlus screenshot (dark theme)
        table.backgroundColor = NSColor(srgbRed: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        table.selectionHighlightStyle = .regular   // .none skips redrawing deselected rows → stale highlights
        table.allowsMultipleSelection = allowsMultipleSelection

        rebuildColumns(table, names: columns)
        context.coordinator.lastColumns = columns
        context.coordinator.syncLayout(table)

        // A user column resize → recompute geometry, repaint visible rows, reposition the cell border.
        NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification, object: table, queue: .main
        ) { [weak table] _ in
            guard let table else { return }
            MainActor.assumeIsolated {
                context.coordinator.syncLayout(table)
                context.coordinator.repaintVisible(table)
            }
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(srgbRed: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.parent = self

        var needsReload = false
        if context.coordinator.lastColumns != columns {
            rebuildColumns(table, names: columns)
            context.coordinator.lastColumns = columns
            context.coordinator.syncLayout(table)
            needsReload = true
        }
        if dataKey != context.coordinator.lastDataKey {
            context.coordinator.lastDataKey = dataKey
            context.coordinator.rebuildColumnMaps()
            needsReload = true
        }
        if needsReload {
            // Reset selection only on a structural change (empty key ⇒ always, for non-editable grids);
            // an edits-only refresh keeps the selection so the detail panel isn't cleared mid-edit.
            let resetSel = selectionKey.isEmpty || selectionKey != context.coordinator.lastSelectionKey
            context.coordinator.lastSelectionKey = selectionKey
            // Streaming append reloads every ~150ms; reloadData drops the row selection. Capture it and
            // restore WITHOUT re-firing onSelect (the restore must not rebuild the detail panel each drain,
            // which throttled streaming throughput) — only when a row is actually selected.
            let keep = resetSel ? nil : (table.selectedRow >= 0 ? table.selectedRowIndexes : nil)
            if resetSel { context.coordinator.resetSelection(table) }
            table.reloadData()
            if let keep, !keep.isEmpty {
                context.coordinator.restoringSelection = true
                table.selectRowIndexes(keep, byExtendingSelection: false)
                context.coordinator.restoringSelection = false
                context.coordinator.repaintVisible(table)
            } else {
                table.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
            }
        }

        // Header redraw is expensive; only touch the sort indicator when the sort (or columns) changed.
        if needsReload || !context.coordinator.sortPrimed
            || context.coordinator.lastSortColumn != sortColumn
            || context.coordinator.lastSortAscending != sortAscending {
            context.coordinator.sortPrimed = true
            context.coordinator.lastSortColumn = sortColumn
            context.coordinator.lastSortAscending = sortAscending
            updateSortIndicator(table)
        }

        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            if let target = focusRow {
                // Defer to next runloop so reloadData has laid out rows before scroll/select.
                DispatchQueue.main.async { [weak table] in
                    guard let table else { return }
                    context.coordinator.focusRow(table, row: target)
                }
            }
        }
    }

    private func updateSortIndicator(_ table: NSTableView) {
        for c in table.tableColumns {
            guard let cell = c.headerCell as? TPPHeaderCell else { continue }
            if c.identifier.rawValue == sortColumn {
                cell.sortState = sortAscending ? 1 : 2
            } else {
                cell.sortState = 0
            }
        }
        table.headerView?.needsDisplay = true
    }

    private func rebuildColumns(_ table: NSTableView, names: [String]) {
        for c in table.tableColumns { table.removeTableColumn(c) }
        for name in names {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            tc.title = name
            tc.width = name == "#" ? 44 : 160
            tc.minWidth = name == "#" ? 36 : 50
            tc.resizingMask = .userResizingMask
            tc.headerCell = TPPHeaderCell(textCell: name)
            table.addTableColumn(tc)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: AppKitDataGrid
        var lastDataKey: String?
        var lastSelectionKey: String?
        var lastFocusToken = 0
        var lastColumns: [String] = []
        var lastSortColumn: String?
        var lastSortAscending: Bool = true
        var sortPrimed = false
        /// Set while programmatically re-selecting after a streaming reload, so selectionDidChange
        /// doesn't re-fire onSelect (which would rebuild the detail panel every drain).
        var restoringSelection = false
        // Cell-provider lookups, rebuilt on data change — avoids an O(columns) linear scan per cell
        // (which made wide tables crawl while scrolling).
        var colIndex: [String: Int] = [:]
        var numericCols: Set<String> = []
        func rebuildColumnMaps() {
            colIndex.removeAll(keepingCapacity: true)
            numericCols.removeAll(keepingCapacity: true)
            guard let cols = parent.rows.first?.columns else { return }
            for (i, c) in cols.enumerated() {
                colIndex[c.name] = i
                if c.isNumeric { numericCols.insert(c.name) }
            }
        }

        // Column geometry for the row-canvas: names + cumulative x-offsets (count+1) + widths.
        // Rebuilt after columns change or a user resize, so draw/hit-test never scan NSTableColumns.
        var colNames: [String] = []
        var colX: [CGFloat] = [0]
        var colW: [CGFloat] = []
        func syncLayout(_ table: NSTableView) {
            colNames = table.tableColumns.map { $0.identifier.rawValue }
            colW = table.tableColumns.map { $0.width }
            colX = [0]
            var x: CGFloat = 0
            for w in colW { x += w; colX.append(x) }
        }
        /// First..last column index intersecting `rect` (row-view coords). Linear but trivial.
        func visibleColumnRange(_ rect: NSRect) -> Range<Int> {
            guard !colW.isEmpty else { return 0..<0 }
            var start = 0
            while start < colW.count && colX[start + 1] <= rect.minX { start += 1 }
            var end = start
            while end < colW.count && colX[end] < rect.maxX { end += 1 }
            return start..<end
        }

        // Overlay inline editor (one shared field) + cached text attributes (no per-cell alloc).
        private let editor = TPPEditField()
        private var editingCell: (row: Int, col: Int)?
        private var editingInitial = ""
        private weak var editorTable: NSTableView?
        static let gridLine = NSColor(srgbRed: 58/255, green: 58/255, blue: 58/255, alpha: 1)
        private static let valueFont = NSFont.systemFont(ofSize: 13)
        private static let placeholderFont = NSFont.systemFont(ofSize: 12)
        private static func attrs(_ font: NSFont, _ color: NSColor, _ align: NSTextAlignment) -> [NSAttributedString.Key: Any] {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            p.alignment = align
            return [.font: font, .foregroundColor: color, .paragraphStyle: p]
        }
        private static let valueLeft  = attrs(valueFont, .labelColor, .left)
        private static let valueRight = attrs(valueFont, .labelColor, .right)
        private static let phLeft     = attrs(placeholderFont, .tertiaryLabelColor, .left)
        private static let valueLineH = ceil(valueFont.ascender - valueFont.descender)
        private static let phLineH    = ceil(placeholderFont.ascender - placeholderFont.descender)
        private static let editBG    = NSColor(srgbRed: 38/255, green: 38/255, blue: 40/255, alpha: 1)
        private static let deletedBG = NSColor(srgbRed: 0.45, green: 0.14, blue: 0.16, alpha: 1)
        private static let dirtyBG   = NSColor(srgbRed: 0.42, green: 0.30, blue: 0.10, alpha: 1)
        private static let newBG     = NSColor(srgbRed: 0.13, green: 0.34, blue: 0.20, alpha: 1)

        private func sanitize(_ s: String?) -> String? {
            guard let s else { return nil }
            if s.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
                return s.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
            }
            return s
        }

        /// Draws every VISIBLE column for one row directly (no per-cell NSView). Called by the row view.
        func drawCells(in rowView: NSView, row: Int) {
            guard parent.rows.indices.contains(row), !colW.isEmpty else { return }
            let vr = rowView.visibleRect
            guard !vr.isEmpty else { return }
            let h = rowView.bounds.height
            // Horizontal separator at the row's bottom (across the visible width) so rows read distinctly.
            Self.gridLine.setFill()
            NSRect(x: vr.minX, y: h - 1, width: vr.width, height: 1).fill()
            let cells = parent.rows[row].cells
            let isInsert = row >= parent.insertRowStart
            let isDeleted = parent.deletedRows.contains(row)
            for col in visibleColumnRange(vr) {
                let name = colNames[col]
                let x = colX[col], w = colW[col]
                let idx = colIndex[name]
                var displayValue: String? = idx.flatMap { cells.indices.contains($0) ? cells[$0].displayText : nil }
                var dirty = false
                if let f = parent.editOverride, let nv = f(row, name) { displayValue = nv; dirty = true }
                let editingThis = editingCell.map { $0.row == row && $0.col == col } ?? false
                let cellRect = NSRect(x: x, y: 0, width: w, height: h)
                if editingThis      { Self.editBG.setFill();    cellRect.fill() }
                else if isDeleted   { Self.deletedBG.setFill(); cellRect.fill() }
                else if dirty       { Self.dirtyBG.setFill();   cellRect.fill() }
                else if isInsert    { Self.newBG.setFill();     cellRect.fill() }
                Self.gridLine.setFill()
                NSRect(x: x + w - 1, y: 0, width: 1, height: h).fill()
                guard !editingThis else { continue }   // editor overlay covers the text
                let numeric = (idx.flatMap { cells.indices.contains($0) ? cells[$0].isNumeric : false } ?? false) || numericCols.contains(name)
                let shown = sanitize(displayValue)
                if let v = shown, !v.isEmpty {
                    let r = NSRect(x: x + 6, y: (h - Self.valueLineH) / 2, width: w - 9, height: Self.valueLineH)
                    (v as NSString).draw(in: r, withAttributes: numeric ? Self.valueRight : Self.valueLeft)
                } else {
                    let ph = displayValue == nil ? "NULL" : "EMPTY"
                    let r = NSRect(x: x + 6, y: (h - Self.phLineH) / 2, width: w - 9, height: Self.phLineH)
                    (ph as NSString).draw(in: r, withAttributes: Self.phLeft)
                }
            }
        }
        private let cellBorder = CellBorderView()      // overlay above the table; not clipped by any cell
        private var selectedCell: (row: Int, col: Int)?
        private var menuTarget: (row: Int, col: Int, colName: String)?
        private var menuRows = IndexSet()
        private weak var menuTable: NSTableView?
        private var editing = false
        private static let red  = NSColor(srgbRed: 0.86, green: 0.52, blue: 0.10, alpha: 1)  // amber (app accent) for selected cell
        private static let blue = NSColor(srgbRed: 0.0,  green: 0.62, blue: 0.74, alpha: 1)  // teal for editing — harmonizes with row highlight
        init(_ parent: AppKitDataGrid) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        /// Repaint visible rows + reposition the cell border / editor (after a column resize).
        func repaintVisible(_ table: NSTableView) {
            table.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
            if let s = selectedCell {
                showBorder(table, row: s.row, col: s.col,
                           color: editing ? Self.blue : Self.red,
                           outset: editing ? 2 : 0, lineWidth: editing ? 2 : 1)
            }
            if let (row, col) = editingCell, colX.indices.contains(col) {
                let rowRect = table.rect(ofRow: row)
                editor.frame = NSRect(x: colX[col], y: rowRect.minY + 3, width: colW[col], height: rowRect.height - 6)
            }
        }

        // First click: select the cell (whole row highlighted + red cell border).
        // Click again on the same cell: enter edit mode.
        @objc func cellClicked(_ sender: NSTableView) {
            guard !editing else { return }
            let row = sender.clickedRow
            guard row >= 0 else { resetSelection(sender); return }
            // Clicking the empty area past the last column (col == -1) still selects the row.
            let col = sender.clickedColumn >= 0 ? sender.clickedColumn : (selectedCell?.col ?? 0)
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if parent.allowsMultipleSelection, mods.contains(.command) || mods.contains(.shift) {
                moveFocus(sender, row: row, col: col)   // keep NSTableView's multi-row selection, just move focus
                return
            }
            if let s = selectedCell, s.row == row, s.col == col, canEdit(sender, row: row, col: col) {
                beginEditing(sender, row: row, col: col)
            } else {
                selectCell(sender, row: row, col: col)
            }
        }

        /// Move the focused cell (border + detail) without collapsing a multi-row selection.
        private func moveFocus(_ table: NSTableView, row: Int, col: Int) {
            selectedCell = (row, col)
            editing = false
            showBorder(table, row: row, col: col, color: Self.red, outset: 0, lineWidth: 1)
            // Detail row is reported by tableViewSelectionDidChange off selectedCell — set above, so
            // it reflects the focused row, not whichever row NSTableView reports as `selectedRow`.
        }

        /// Scroll to a row and focus its first editable cell (used after Insert / Duplicate).
        func focusRow(_ table: NSTableView, row: Int) {
            guard row >= 0, row < table.numberOfRows else { return }
            table.scrollRowToVisible(row)
            var targetCol = 0
            for c in 0..<table.tableColumns.count where canEdit(table, row: row, col: c) { targetCol = c; break }
            selectCell(table, row: row, col: targetCol)
        }

        func handleDeleteKey(_ table: NSTableView) -> Bool {
            guard parent.editable, parent.onDeleteRows != nil, !editing else { return false }
            let sel = table.selectedRowIndexes
            guard !sel.isEmpty else { return false }
            parent.onDeleteRows?(sel)
            return true
        }

        @objc func cellDoubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow, col = sender.clickedColumn
            guard canEdit(sender, row: row, col: col) else { return }
            selectedCell = (row, col)
            beginEditing(sender, row: row, col: col)
        }

        // MARK: - Context menu

        func contextMenu(for event: NSEvent, in table: NSTableView) -> NSMenu? {
            guard parent.onCellAction != nil else { return nil }
            let pt = table.convert(event.locationInWindow, from: nil)
            let row = table.row(at: pt), col = table.column(at: pt)
            guard row >= 0, col >= 0, col < table.tableColumns.count, parent.rows.indices.contains(row) else { return nil }
            let colName = table.tableColumns[col].identifier.rawValue
            // Finder rule: right-clicking inside a multi-row selection keeps it (menu acts on all);
            // right-clicking outside collapses to that single row.
            let selected = table.selectedRowIndexes
            if parent.allowsMultipleSelection, selected.contains(row), selected.count > 1 {
                menuRows = selected
                moveFocus(table, row: row, col: col)
            } else {
                selectCell(table, row: row, col: col)   // single-select → right-panel detail stays in sync
                menuRows = IndexSet(integer: row)
            }
            menuTarget = (row, col, colName)
            menuTable = table
            let editable = canEdit(table, row: row, col: col)
            let isInsert = row >= parent.insertRowStart
            let isDeleted = parent.deletedRows.contains(row)

            let menu = NSMenu()
            func add(_ key: String, _ sel: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: L10n.t(key), action: sel, keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            }
            add("menu.copyCell", #selector(menuCopyCell))
            add("menu.copyRowJSON", #selector(menuCopyRowJSON))
            add("menu.copyRowInsert", #selector(menuCopyRowInsert))
            menu.addItem(.separator())
            add("menu.edit", #selector(menuEdit), enabled: editable)
            add("menu.setNull", #selector(menuSetNull), enabled: editable)
            add("menu.setEmpty", #selector(menuSetEmpty), enabled: editable)
            menu.addItem(.separator())
            add("menu.filterValue", #selector(menuFilter), enabled: !isInsert && !isDeleted)   // no DB meaning for draft / pending-delete
            menu.addItem(.separator())
            add("menu.insertRow", #selector(menuInsertRow))
            add("menu.duplicateRow", #selector(menuDuplicateRow), enabled: !isInsert && !isDeleted)
            let allDeleted = menuRows.allSatisfy { parent.deletedRows.contains($0) }
            let delTitle: String
            if menuRows.count > 1 {
                delTitle = String(format: L10n.t(allDeleted ? "menu.cancelDeleteRowsN" : "menu.deleteRowsN"), menuRows.count)
            } else {
                delTitle = L10n.t(isDeleted ? "menu.cancelDelete" : "menu.deleteRow")
            }
            let delItem = NSMenuItem(title: delTitle, action: #selector(menuDeleteRows), keyEquivalent: "")
            delItem.target = self
            menu.addItem(delItem)
            return menu
        }

        @objc private func menuCopyCell() { emit(.copyCell) }
        @objc private func menuCopyRowJSON() { emit(.copyRowJSON) }
        @objc private func menuCopyRowInsert() { emit(.copyRowInsert) }
        @objc private func menuSetNull() { emit(.setNull) }
        @objc private func menuSetEmpty() { emit(.setEmpty) }
        @objc private func menuFilter() { emit(.filterByValue) }
        @objc private func menuInsertRow() { emit(.insertRow) }
        @objc private func menuDuplicateRow() { emit(.duplicateRow) }
        @objc private func menuDeleteRows() { parent.onDeleteRows?(menuRows) }

        @objc private func menuEdit() {
            guard let t = menuTarget, let table = menuTable, canEdit(table, row: t.row, col: t.col) else { return }
            beginEditing(table, row: t.row, col: t.col)
        }

        private func emit(_ action: GridCellAction) {
            guard let t = menuTarget else { return }
            parent.onCellAction?(action, t.row, t.colName)
        }

        private func canEdit(_ table: NSTableView, row: Int, col: Int) -> Bool {
            guard parent.editable, row >= 0, col >= 0, col < table.tableColumns.count, parent.rows.indices.contains(row) else { return false }
            if parent.deletedRows.contains(row) { return false }   // row marked for deletion
            let colName = table.tableColumns[col].identifier.rawValue
            if row >= parent.insertRowStart {   // insert draft: editable unless the DB computes the column
                return !parent.nonEditableInsertColumns.contains(colName)
            }
            if (parent.rows[row].cell(colName) ?? .null).isBinaryLike { return false }
            return true
        }

        private func selectCell(_ table: NSTableView, row: Int, col: Int) {
            selectedCell = (row, col)
            editing = false
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)   // whole row highlighted
            showBorder(table, row: row, col: col, color: Self.red, outset: 0, lineWidth: 1)   // thin dark-red on the cell
        }

        private func colName(_ table: NSTableView, _ col: Int) -> String {
            colNames.indices.contains(col) ? colNames[col] : table.tableColumns[col].identifier.rawValue
        }

        private func beginEditing(_ table: NSTableView, row: Int, col: Int) {
            endEditing(commit: true)   // commit any in-flight edit first
            editing = true
            selectedCell = (row, col)
            editingCell = (row, col)
            editorTable = table
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            showBorder(table, row: row, col: col, color: Self.blue, outset: 2, lineWidth: 2)
            let name = colName(table, col)
            // Edit the CURRENT value (pending override if any), not the original.
            var editValue = (parent.rows[row].cell(name) ?? .null).displayText ?? ""
            if let f = parent.editOverride, let nv = f(row, name) { editValue = nv ?? "" }
            editingInitial = editValue
            let rowRect = table.rect(ofRow: row)
            let x = colX.indices.contains(col) ? colX[col] : table.rect(ofColumn: col).minX
            let w = colW.indices.contains(col) ? colW[col] : table.rect(ofColumn: col).width
            editor.delegate = self
            editor.stringValue = editValue
            // Slightly inset vertically so the single-line text reads centred in the row.
            editor.frame = NSRect(x: x, y: rowRect.minY + 3, width: w, height: rowRect.height - 6)
            table.addSubview(editor, positioned: .above, relativeTo: nil)
            table.window?.makeFirstResponder(editor)
            editor.currentEditor()?.selectedRange = NSRange(location: 0, length: (editValue as NSString).length)
            table.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }

        /// Tear down the overlay editor; commit the value unless cancelled. Idempotent.
        func endEditing(commit: Bool) {
            guard let (row, col) = editingCell, let table = editorTable else { return }
            let value = editor.stringValue
            editingCell = nil
            editing = false
            editor.delegate = nil
            editor.removeFromSuperview()
            if commit, parent.editable, value != editingInitial {   // unchanged ⇒ no edit (keeps NULL as NULL)
                parent.onEditCommit?(row, colName(table, col), value)
            }
            table.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            if let s = selectedCell, s.row == row { selectCell(table, row: s.row, col: s.col) }
        }

        // Enter commits, Esc cancels, Tab commits (field-editor command interception).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): endEditing(commit: true); return true
            case #selector(NSResponder.cancelOperation(_:)): endEditing(commit: false); return true
            case #selector(NSResponder.insertTab(_:)): endEditing(commit: true); return true
            default: return false
            }
        }

        private func showBorder(_ table: NSTableView, row: Int, col: Int, color: NSColor, outset: CGFloat, lineWidth: CGFloat) {
            guard col < table.tableColumns.count, row >= 0 else { return }
            let colRect = table.rect(ofColumn: col)
            let rowRect = table.rect(ofRow: row)
            let cellRect = NSRect(x: colRect.minX, y: rowRect.minY, width: colRect.width, height: rowRect.height)
            cellBorder.color = color
            cellBorder.lineWidth = lineWidth
            cellBorder.frame = cellRect.insetBy(dx: -outset, dy: -outset)
            table.addSubview(cellBorder, positioned: .above, relativeTo: nil)
            cellBorder.needsDisplay = true
        }

        func resetSelection(_ table: NSTableView) {
            if editingCell != nil { endEditing(commit: true) }
            selectedCell = nil
            editing = false
            editingCell = nil
            cellBorder.removeFromSuperview()
            if table.selectedRow >= 0 { table.deselectAll(nil) }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            endEditing(commit: true)
        }

        /// No per-cell NSViews: the row view draws every visible cell itself.
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row >= 0, row < parent.rows.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("row")
            let rv = (tableView.makeView(withIdentifier: id, owner: nil) as? TPPGridRowView) ?? TPPGridRowView()
            rv.identifier = id
            rv.coord = self
            rv.rowIndex = row
            rv.bg = row % 2 == 0
                ? NSColor(srgbRed: 30/255, green: 30/255, blue: 30/255, alpha: 1)
                : NSColor(srgbRed: 41/255, green: 41/255, blue: 41/255, alpha: 1)
            rv.needsDisplay = true
            return rv
        }

        func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
            parent.onHeaderClick?(tableColumn.identifier.rawValue)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            if restoringSelection { return }   // streaming reload re-select: don't rebuild the detail panel
            let cb = parent.onSelect
            // Dispatch so selectedCell (set in the click/menu handler that runs after this notification)
            // is current; prefer the focused cell's row over NSTableView's `selectedRow` (multi-select).
            DispatchQueue.main.async { [weak self] in
                let row = self?.selectedCell?.row ?? (table.selectedRow >= 0 ? table.selectedRow : nil)
                cb?(row)
            }
        }
    }
}

/// The single overlay editor placed over the cell being edited (added to the table, so it scrolls
/// with the content). Styled like the old in-cell input box.
final class TPPEditField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        drawsBackground = true
        backgroundColor = NSColor(srgbRed: 38/255, green: 38/255, blue: 40/255, alpha: 1)
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 13)
        textColor = .labelColor
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Cell border (red = selected, blue = editing), overlaid above the table so it isn't clipped
/// to a cell and can sit on / outside the column separators. Transparent to mouse events.
private final class CellBorderView: NSView {
    var color: NSColor = .red { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 2 { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let i = lineWidth / 2
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: i, dy: i), xRadius: 2, yRadius: 2)
        ring.lineWidth = lineWidth
        color.setStroke()
        ring.stroke()
    }
}

private final class TPPTableView: NSTableView {
    weak var coordinator: AppKitDataGrid.Coordinator?

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.contextMenu(for: event, in: self)
    }

    override func keyDown(with event: NSEvent) {
        // 51 = delete (backspace), 117 = forward delete → delete selected rows
        if event.keyCode == 51 || event.keyCode == 117, coordinator?.handleDeleteKey(self) == true { return }
        super.keyDown(with: event)
    }
}

/// Row-canvas: one NSView per visible row that draws ALL of that row's visible cells in draw(_:),
/// instead of one NSTextField per cell. Cuts live views from rows×columns to rows.
private final class TPPGridRowView: NSTableRowView {
    weak var coord: AppKitDataGrid.Coordinator?
    var rowIndex = -1
    var bg: NSColor = NSColor(srgbRed: 30/255, green: 30/255, blue: 30/255, alpha: 1)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func drawBackground(in dirtyRect: NSRect) {
        bg.setFill()
        bounds.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(srgbRed: 0/255, green: 117/255, blue: 143/255, alpha: 0.45).setFill()
        bounds.fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        // Explicit order — super.draw() doesn't reliably fill the row background for every row.
        drawBackground(in: dirtyRect)
        if isSelected { drawSelection(in: dirtyRect) }
        coord?.drawCells(in: self, row: rowIndex)
    }
}

private final class TPPHeaderView: NSTableHeaderView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: 32))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 45/255, green: 45/255, blue: 47/255, alpha: 1).setFill()
        bounds.fill()
        super.draw(dirtyRect)
        // bottom shadow border for the raised bar
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: bounds.minY, width: bounds.width, height: 1).fill()
    }
}

private final class TPPHeaderCell: NSTableHeaderCell {
    var sortState: Int = 0   // 0 none, 1 asc, 2 desc

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor(srgbRed: 45/255, green: 45/255, blue: 47/255, alpha: 1).setFill()
        cellFrame.fill()

        // Top highlight line → raised feel
        NSColor(white: 1.0, alpha: 0.10).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()

        // Right separator
        let sepInset: CGFloat = 8
        NSColor(white: 1.0, alpha: 0.16).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + sepInset,
               width: 1, height: cellFrame.height - sepInset * 2).fill()

        if sortState != 0 { drawCaret(in: cellFrame, up: sortState == 1) }

        drawInterior(withFrame: cellFrame.insetBy(dx: 6, dy: 0), in: controlView)
    }

    private func drawCaret(in cellFrame: NSRect, up: Bool) {
        let w: CGFloat = 6, h: CGFloat = 3.5
        let cx = cellFrame.maxX - 13
        let cy = cellFrame.midY
        let p = NSBezierPath()
        if up {
            p.move(to: NSPoint(x: cx - w/2, y: cy - h/2))
            p.line(to: NSPoint(x: cx, y: cy + h/2))
            p.line(to: NSPoint(x: cx + w/2, y: cy - h/2))
        } else {
            p.move(to: NSPoint(x: cx - w/2, y: cy + h/2))
            p.line(to: NSPoint(x: cx, y: cy - h/2))
            p.line(to: NSPoint(x: cx + w/2, y: cy + h/2))
        }
        p.lineWidth = 1.2
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        NSColor(white: 1.0, alpha: 0.35).setStroke()
        p.stroke()
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: stringValue, attributes: attrs)
        let size = text.size()
        let y = cellFrame.midY - size.height / 2
        let x = cellFrame.midX - size.width / 2
        text.draw(at: NSPoint(x: x, y: y))
    }
}
