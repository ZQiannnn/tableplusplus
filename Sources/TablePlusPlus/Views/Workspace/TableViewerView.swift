import SwiftUI
import AppKit

struct TableViewerView: View {
    @Environment(SessionStore.self) private var session
    let table: String
    @State private var columnsOpen = false
    @State private var whereDraft = ""
    @State private var orderDraft = ""
    @State private var confirmRefresh = false
    private var cmds: AppCommands { .shared }

    /// Reloading drops uncommitted edits, so confirm first when the tab is dirty.
    private func requestRefresh() {
        if session.hasEdits { confirmRefresh = true }
        else { Task { await session.reloadCurrentTable() } }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch session.viewerMode {
            case .data:      dataContent
            case .structure: StructureView(table: table)
            }

            Divider()

            footerToolbar
        }
        .background(Color(.windowBackgroundColor))
        .task(id: session.activeTabState?.id) {
            // Load only when this tab has never loaded; switching back to a loaded tab is a pure
            // state switch (no query). Use the tab's own name, never the possibly-stale `table` param.
            if let tab = session.activeTabState, !tab.loaded {
                await session.openTable(tab.table)
            }
        }
        .onChange(of: session.viewerMode) { _, _ in
            session.clearDetail()
        }
        .onChange(of: cmds.runOrRefresh) { _, _ in
            requestRefresh()
        }
        .sheet(isPresented: $confirmRefresh) {
            ConfirmDialog(
                title: L10n.t("edit.refreshWarnTitle"),
                message: L10n.t("edit.refreshWarnMsg"),
                confirmLabel: L10n.t("edit.discard"),
                destructive: true,
                onConfirm: {
                    confirmRefresh = false
                    Task { await session.reloadCurrentTable() }
                },
                onCancel: { confirmRefresh = false }
            )
        }
    }

    @ViewBuilder private var dataContent: some View {
        VStack(spacing: 0) {
            whereOrderBar
                .zIndex(1)
            Divider()
            draftBar
            Divider()
            // Grid stays mounted under the preview overlay so toggling SQL preview preserves
            // the data grid's scroll position and selection.
            ZStack {
                dataGridArea
                if session.showEditSQL && session.hasEdits {
                    SQLHighlightView(text: session.editSQLText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    static let editAmber = Color(red: 0.85, green: 0.60, blue: 0.17)
    static let editTeal  = Color(red: 0.0,  green: 0.62, blue: 0.74)

    // Draft-edit controls for the current data grid — always visible, disabled when no edits.
    private var draftBar: some View {
        HStack(spacing: 8) {
            Button { session.focusNextEditedRow() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil").font(.system(size: 11))
                    Text("\(session.draftCount)").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(session.hasEdits ? .black : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(session.hasEdits ? Self.editAmber : Color.secondary.opacity(0.18)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!session.hasEdits)
            .help(L10n.t("edit.jumpToEdit"))

            Text(session.hasEdits ? L10n.t("edit.hintUnsaved") : L10n.t("edit.hintEdit"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button { session.discardEdits() } label: {
                Label(L10n.t("edit.discard"), systemImage: "arrow.uturn.backward")
            }
            .controlSize(.regular)
            .disabled(!session.hasEdits)

            Button { session.showEditSQL.toggle() } label: {
                Label(session.showEditSQL ? L10n.t("edit.backToData") : L10n.t("edit.preview"),
                      systemImage: session.showEditSQL ? "tablecells" : "eye")
            }
            .controlSize(.regular)
            .tint(session.showEditSQL ? Self.editTeal : nil)
            .disabled(!session.hasEdits)

            Button { commitEdits() } label: {
                Label(L10n.t("edit.commit"), systemImage: "checkmark")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            .tint(Self.editAmber)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!session.hasEdits || session.committing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DataGrid.bgChrome)
    }

    private func commitEdits() {
        Task { if let err = await session.commitEdits() { session.error = err } }
    }

    // One persistent grid per open tab in the active context. Switching tabs only flips opacity —
    // the already-built NSTableView for the target tab shows instantly (no column rebuild / reload).
    @ViewBuilder private var dataGridArea: some View {
        ZStack {
            if let ctx = session.activeContext {
                let activeID = ctx.activeTabID
                ForEach(ctx.tabs) { tab in
                    let active = tab.id == activeID
                    TabDataGrid(tab: tab, isActive: active)
                        .frame(maxWidth: active ? .infinity : 0, maxHeight: active ? .infinity : 0)
                        .clipped()
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                }
            }
        }
    }

    private var whereOrderBar: some View {
        HStack(spacing: 8) {
            Text("WHERE")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Self.whereColor)
            SQLInputField(text: $whereDraft, columns: columnList, keywords: Self.whereKeywords, onSubmit: applyWhereOrder, focusTrigger: cmds.focusWhere)
                .frame(maxWidth: .infinity)

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16)

            Text("ORDER BY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Self.orderColor)
            SQLInputField(text: $orderDraft, columns: columnList, keywords: Self.orderKeywords, onSubmit: applyWhereOrder)
                .frame(maxWidth: .infinity)

            Button {
                requestRefresh()
            } label: {
                Label(L10n.t("workspace.refresh"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(session.tableLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(DataGrid.bgChrome)
        .onChange(of: session.currentTable) { _, _ in
            whereDraft = session.whereText
            orderDraft = session.orderByText
        }
        .onChange(of: session.whereText) { _, new in
            whereDraft = new
        }
    }

    private func applyWhereOrder() {
        Task { await session.applyWhereOrder(where: whereDraft, orderBy: orderDraft) }
    }

    static let whereColor = Color(red: 0.00, green: 0.46, blue: 0.56)   // icon teal
    static let orderColor = Color(red: 0.97, green: 0.55, blue: 0.07)   // icon orange

    static let whereKeywords = ["AND", "OR", "NOT", "IS", "NULL", "IS NULL", "IS NOT NULL",
                                "IN", "LIKE", "BETWEEN", "EXISTS", "TRUE", "FALSE"]
    static let orderKeywords = ["ASC", "DESC"]

    private var footerToolbar: some View {
        HStack(spacing: 12) {
            modeSwitch

            if session.viewerMode == .data {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
                columnsButton
                Button { session.insertRow() } label: {
                    Label(L10n.t("menu.insertRow"), systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(session.currentTable == nil)
            } else {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
                structureActionButton(L10n.t("structure.addIndex"), system: "plus")
                structureActionButton(L10n.t("structure.addColumn"), system: "plus")
                structureSectionButton(L10n.t("structure.triggers"), section: .triggers)
                structureSectionButton(L10n.t("structure.info"), section: .info)
            }

            Spacer()

            if session.viewerMode == .data {
                Text(rowsLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        Task { await session.prevPage() }
                    } label: { Image(systemName: "chevron.left") }
                        .disabled(session.tableOffset == 0 || session.tableLoading)
                    Button {
                        Task { await session.nextPage() }
                    } label: { Image(systemName: "chevron.right") }
                        .disabled(session.tableLoading || !hasMore)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DataGrid.bgChrome)
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            segment(L10n.t("workspace.tabData"), mode: .data)
            segment(L10n.t("workspace.tabStructure"), mode: .structure)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func segment(_ title: String, mode m: SessionStore.ViewerMode) -> some View {
        let active = session.viewerMode == m
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) { session.viewerMode = m }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.horizontal, 16).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Color.white.opacity(0.16) : .clear)
                        .shadow(color: active ? .black.opacity(0.3) : .clear, radius: 1, y: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func structureActionButton(_ title: String, system: String?) -> some View {
        Button {} label: {
            if let system { Label(title, systemImage: system) } else { Text(title) }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func structureSectionButton(_ title: String, section: SessionStore.StructureSection) -> some View {
        let active = session.structureSection == section
        return Button {
            session.structureSection = active ? .fields : section
        } label: {
            Text(title)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(active ? Self.whereColor : nil)
    }

    private var columnsButton: some View {
        Button { columnsOpen.toggle() } label: {
            footerChip(icon: "tablecells.badge.ellipsis",
                       text: L10n.t("workspace.columns"),
                       badge: session.hiddenColumns.isEmpty ? nil : "\(session.hiddenColumns.count)")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $columnsOpen, arrowEdge: .top) {
            ColumnsPopover(columns: columnList, hidden: session.hiddenColumns) { hidden in
                session.setHiddenColumns(hidden)
            }
        }
    }

    private var columnList: [String] {
        session.allTableColumns.isEmpty ? session.tableColumns : session.allTableColumns
    }

    private func footerChip(icon: String, text: String, badge: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 11))
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.8)))
            }
        }
        .foregroundStyle(badge == nil ? .secondary : .primary)
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    private var rowsLabel: String {
        let shown = session.tableRows.count
        if let total = session.tableTotal {
            let from = session.tableOffset + (shown > 0 ? 1 : 0)
            let to = session.tableOffset + shown
            return "\(from)-\(to) of \(total)"
        }
        return "\(shown) rows"
    }

    private var hasMore: Bool {
        guard let total = session.tableTotal else { return session.tableRows.count == session.tablePageSize }
        return session.tableOffset + session.tableRows.count < total
    }
}

// MARK: - SQLInputField (column-name autocomplete)

// A single tab's data grid. Kept alive in the dataGridArea ZStack so switching tabs is a pure
// visibility flip. Display reads come from `tab`; mutations go through `session` (active tab only).
private struct TabDataGrid: View {
    let tab: TableTabState
    let isActive: Bool
    @Environment(SessionStore.self) private var session

    private var baseKey: String {
        "\(tab.id)|\(tab.tableOffset)|\(tab.tableRows.count)|\(tab.insertDrafts.count)|\(tab.displayColumns.count)|\(tab.whereText)|\(tab.orderByText)|\(tab.orderBy.first?.column ?? "")|\(tab.orderBy.first?.ascending == true ? 1 : 0)"
    }
    private var dataKey: String { "\(baseKey)|e\(tab.editsVersion)|l\(tab.loadToken)" }

    var body: some View {
        if tab.tableLoading && tab.tableRows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tab.tableColumns.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(L10n.t("workspace.emptyTable"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AppKitDataGrid(
                columns: tab.displayColumns,
                rows: tab.gridRows,
                dataKey: dataKey,
                selectionKey: baseKey,
                sortColumn: tab.orderBy.first?.column,
                sortAscending: tab.orderBy.first?.ascending ?? true,
                onSelect: { i in
                    guard isActive else { return }
                    if let i { session.showDataRowDetail(i) } else { session.clearDetail() }
                },
                onHeaderClick: { col in
                    guard isActive else { return }
                    Task { await session.toggleSort(col) }
                },
                editable: true,
                insertRowStart: tab.tableRows.count,
                nonEditableInsertColumns: tab.insertSkipColumns,
                deletedRows: tab.deletedRows,
                focusToken: tab.focusToken,
                focusRow: tab.focusGridRow,
                editOverride: { tab.editOverride(row: $0, column: $1) },
                onEditCommit: { row, col, value in
                    guard isActive else { return }
                    session.setEdit(row: row, column: col, newValue: value)
                },
                onCellAction: { action, row, col in
                    guard isActive else { return }
                    handleCellAction(action, row, col)
                },
                onDeleteRows: { guard isActive else { return }; session.toggleDelete($0) },
                allowsMultipleSelection: true
            )
        }
    }

    private func handleCellAction(_ action: GridCellAction, _ row: Int, _ col: String) {
        switch action {
        case .copyCell:       session.copyCell(row: row, column: col)
        case .copyRowJSON:    session.copyRowAsJSON(row)
        case .copyRowInsert:  session.copyRowAsInsert(row)
        case .setNull:        session.setCellValue(row: row, column: col, newValue: nil)
        case .setEmpty:       session.setCellValue(row: row, column: col, newValue: "")
        case .filterByValue:  Task { await session.filterByValue(row: row, column: col) }
        case .insertRow:      session.insertRow()
        case .duplicateRow:   session.duplicateRow(row)
        }
    }
}

struct SQLInputField: View {
    @Binding var text: String
    let columns: [String]
    let keywords: [String]
    var onSubmit: () -> Void
    var focusTrigger: Int = 0
    @State private var focused = false
    @State private var selectedIndex = 0
    @State private var dismissed = false

    private static let separators = CharacterSet(charactersIn: " \t\n,()=<>!+-*/'\"`;")

    private var currentToken: String {
        text.components(separatedBy: Self.separators).last ?? ""
    }

    private var suggestions: [String] {
        let tok = currentToken.lowercased()
        guard !tok.isEmpty else { return [] }
        let cols = columns.filter { $0.lowercased().hasPrefix(tok) && $0.lowercased() != tok }
        let kws = keywords.filter { $0.lowercased().hasPrefix(tok) && $0.lowercased() != tok }
        return Array((cols + kws).prefix(10))
    }

    private var showSug: Bool { focused && !dismissed && !suggestions.isEmpty }

    var body: some View {
        CompletionTextField(
            text: $text,
            onMoveUp: { guard showSug else { return false }; selectedIndex = max(0, selectedIndex - 1); return true },
            onMoveDown: { guard showSug else { return false }; selectedIndex = min(suggestions.count - 1, selectedIndex + 1); return true },
            onTab: { guard showSug else { return false }; acceptSelected(); return true },
            onEnter: { if showSug { acceptSelected() } else { onSubmit() }; return true },
            onCancel: { guard showSug else { return false }; dismissed = true; return true },
            onFocus: { f in focused = f },
            focusTrigger: focusTrigger
        )
        .frame(height: 18)
        .overlay(alignment: .topLeading) {
            if showSug { suggestionList.offset(y: 20) }
        }
        .onChange(of: text) { _, _ in selectedIndex = 0; dismissed = false }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { i, s in
                SuggestionRow(
                    text: s,
                    isKeyword: keywords.contains(s),
                    selected: i == selectedIndex
                ) { apply(s) }
            }
        }
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 38/255, green: 38/255, blue: 40/255)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    private func acceptSelected() {
        guard suggestions.indices.contains(selectedIndex) else { return }
        apply(suggestions[selectedIndex])
    }

    private func apply(_ s: String) {
        let tok = currentToken
        if !tok.isEmpty { text = String(text.dropLast(tok.count)) }
        text += s
        focused = true
        selectedIndex = 0
    }
}

private struct SuggestionRow: View {
    let text: String
    let isKeyword: Bool
    let selected: Bool
    var onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isKeyword ? TableViewerView.orderColor : .primary)
            Spacer(minLength: 0)
            if isKeyword {
                Text("kw")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            selected ? TableViewerView.whereColor.opacity(0.40)
                     : (hovered ? Color.white.opacity(0.10) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovered = $0 }
    }
}

private struct CompletionTextField: NSViewRepresentable {
    @Binding var text: String
    var onMoveUp: () -> Bool
    var onMoveDown: () -> Bool
    var onTab: () -> Bool
    var onEnter: () -> Bool
    var onCancel: () -> Bool
    var onFocus: (Bool) -> Void
    var focusTrigger: Int = 0

    func makeNSView(context: Context) -> NSTextField {
        let tf = FocusTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        tf.lineBreakMode = .byClipping
        tf.onFocusChange = { context.coordinator.parent.onFocus($0) }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.stringValue != text {
            tf.stringValue = text
            tf.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        if focusTrigger != 0, context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { [weak tf] in
                guard let tf, let window = tf.window else { return }
                window.makeFirstResponder(tf)
                tf.currentEditor()?.selectedRange = NSRange(location: (tf.stringValue as NSString).length, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletionTextField
        var lastFocusTrigger = 0
        init(_ p: CompletionTextField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocus(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)):          return parent.onMoveUp()
            case #selector(NSResponder.moveDown(_:)):        return parent.onMoveDown()
            case #selector(NSResponder.insertTab(_:)):       return parent.onTab()
            case #selector(NSResponder.insertNewline(_:)):   return parent.onEnter()
            case #selector(NSResponder.cancelOperation(_:)): return parent.onCancel()
            default: return false
            }
        }
    }
}

private final class FocusTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }
}

// MARK: - SQLHighlightView (read-only, syntax-highlighted)

struct SQLHighlightView: NSViewRepresentable {
    let text: String
    var scrollsToEnd: Bool = false

    private static let bg = NSColor(srgbRed: 24/255, green: 24/255, blue: 24/255, alpha: 1)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = Self.bg
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.bg
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.textStorage?.setAttributedString(Self.highlight(text))
            if scrollsToEnd { tv.scrollToEndOfDocument(nil) }
        }
    }

    static func highlight(_ sql: String) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: sql)
        applyHighlight(to: attr)
        return attr
    }

    /// In-place attribute pass (font + colors only, characters untouched) so an editable
    /// NSTextView can re-highlight after edits without resetting the cursor.
    static func applyHighlight(to attr: NSMutableAttributedString) {
        let sql = attr.string
        let len = (sql as NSString).length
        attr.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(white: 0.90, alpha: 1),
        ], range: NSRange(location: 0, length: len))
        func color(_ pattern: String, _ c: NSColor) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            re.enumerateMatches(in: sql, range: NSRange(location: 0, length: len)) { m, _, _ in
                if let r = m?.range { attr.addAttribute(.foregroundColor, value: c, range: r) }
            }
        }
        let keywords = ["CREATE","TABLE","NOT","NULL","DEFAULT","PRIMARY","KEY","UNIQUE","ENGINE",
                        "CHARACTER","SET","COLLATE","COMMENT","AUTO_INCREMENT","CURRENT_TIMESTAMP",
                        "ON","UPDATE","USING","BTREE","HASH","REFERENCES","FOREIGN","CONSTRAINT",
                        "INDEX","FULLTEXT","TEMPORARY","IF","EXISTS","UNSIGNED","ZEROFILL","GENERATED","VIRTUAL","STORED",
                        "INSERT","INTO","VALUES","DELETE","FROM","WHERE","LIMIT","AND","OR","IN","IS","LIKE",
                        "ORDER","BY","ASC","DESC","SELECT","START","TRANSACTION","COMMIT","ROLLBACK","OFFSET"]
        let types = ["bigint","int","integer","tinyint","smallint","mediumint","varchar","char","text",
                     "longtext","mediumtext","tinytext","datetime","timestamp","date","time","year",
                     "decimal","numeric","double","float","blob","longblob","mediumblob","tinyblob","json","enum","bit","boolean","bool"]
        color("\\b(\(keywords.joined(separator: "|")))\\b", NSColor(srgbRed: 0.34, green: 0.61, blue: 0.84, alpha: 1))
        color("\\b(\(types.joined(separator: "|")))\\b", NSColor(srgbRed: 0.31, green: 0.79, blue: 0.69, alpha: 1))
        color("`[^`]*`", NSColor(srgbRed: 0.61, green: 0.86, blue: 0.99, alpha: 1))
        color("'(?:[^']|'')*'", NSColor(srgbRed: 0.81, green: 0.57, blue: 0.47, alpha: 1))
        color("--[^\\n]*", NSColor(srgbRed: 0.46, green: 0.60, blue: 0.36, alpha: 1))
    }
}

// MARK: - FiltersPopover

struct FiltersPopover: View {
    let columns: [String]
    var onApply: ([FilterCondition]) -> Void

    @Environment(SessionStore.self) private var session
    @State private var conditions: [FilterCondition] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("workspace.filters"))
                .font(.system(size: 12, weight: .semibold))

            if conditions.isEmpty {
                Text(L10n.t("workspace.noFilters"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach($conditions) { $cond in
                    HStack(spacing: 6) {
                        Picker("", selection: $cond.column) {
                            Text("—").tag("")
                            ForEach(columns, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        Picker("", selection: $cond.op) {
                            ForEach(FilterOp.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)

                        if cond.op.needsValue {
                            TextField(L10n.t("workspace.filterValue"), text: $cond.value)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        } else {
                            Spacer().frame(width: 120)
                        }

                        Button {
                            conditions.removeAll { $0.id == cond.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button {
                    conditions.append(FilterCondition(column: columns.first ?? ""))
                } label: {
                    Label(L10n.t("workspace.addCondition"), systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(L10n.t("workspace.clear")) {
                    conditions = []
                    onApply([])
                }
                .disabled(conditions.isEmpty && session.filters.isEmpty)

                Button(L10n.t("workspace.apply")) {
                    onApply(conditions)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 480)
        .onAppear {
            conditions = session.filters
            if conditions.isEmpty {
                conditions = [FilterCondition(column: columns.first ?? "")]
            }
        }
    }
}

// MARK: - ColumnsPopover

struct ColumnsPopover: View {
    let columns: [String]
    let hidden: Set<String>
    var onChange: (Set<String>) -> Void

    @State private var hiddenSet: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("workspace.columns"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L10n.t("workspace.showAll")) {
                    hiddenSet = []
                    onChange(hiddenSet)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                Button(L10n.t("workspace.hideAll")) {
                    hiddenSet = Set(columns)
                    onChange(hiddenSet)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(columns, id: \.self) { col in
                        Toggle(isOn: Binding(
                            get: { !hiddenSet.contains(col) },
                            set: { show in
                                if show { hiddenSet.remove(col) } else { hiddenSet.insert(col) }
                                onChange(hiddenSet)
                            }
                        )) {
                            Text(col).font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { hiddenSet = hidden }
    }
}

// MARK: - StructureView

struct StructureView: View {
    @Environment(SessionStore.self) private var session
    let table: String
    @State private var colSearch: String = ""
    @FocusState private var searchFocused: Bool

    private let colHeaders = ["#", "column_name", "data_type", "character_set", "collation",
                              "is_nullable", "column_default", "extra", "foreign_key", "comment"]
    private let idxHeaders = ["index_name", "index_algorithm", "is_unique", "column_name"]

    private var filteredColumns: [(offset: Int, element: TableColumnInfo)] {
        let all = Array(session.tableSchema.enumerated())
        guard !colSearch.isEmpty else { return all.map { ($0.offset, $0.element) } }
        return all.filter { $0.element.name.localizedCaseInsensitiveContains(colSearch) }
            .map { ($0.offset, $0.element) }
    }

    private var pkColumns: [String] {
        session.tableSchema.filter { $0.key == "PRI" }.map { $0.name }
    }

    struct GridSort: Equatable { var key: String; var asc: Bool }
    @State private var colSort: GridSort?
    @State private var idxSort: GridSort?
    @State private var trigSort: GridSort?

    /// Cycle: default → DESC → ASC → default.
    private func cycled(_ s: GridSort?, _ key: String) -> GridSort? {
        if s?.key == key { return s!.asc ? nil : GridSort(key: key, asc: true) }
        return GridSort(key: key, asc: false)
    }

    private func sortItems(_ items: [(Int, DriverRow)], _ s: GridSort?) -> [(Int, DriverRow)] {
        guard let s else { return items }
        return items.sorted { a, b in
            let x = a.1.string(s.key) ?? "", y = b.1.string(s.key) ?? ""
            let asc: Bool
            if let nx = Double(x), let ny = Double(y) { asc = nx < ny }
            else { asc = x.localizedStandardCompare(y) == .orderedAscending }
            return s.asc ? asc : !asc
        }
    }

    private func columnRow(_ c: TableColumnInfo, _ ordinal: Int) -> DriverRow {
        DriverRow(columns: colHeaders, values: [
            "#": "\(ordinal + 1)",
            "column_name": c.name,
            "data_type": c.type,
            "character_set": c.characterSet,
            "collation": c.collation,
            "is_nullable": c.nullable ? "YES" : "NO",
            "column_default": c.default,
            "extra": c.extra,
            "foreign_key": c.foreignKey ?? "",
            "comment": c.comment,
        ])
    }

    private var columnItems: [(Int, DriverRow)] {
        sortItems(filteredColumns.map { ($0.offset, columnRow($0.element, $0.offset)) }, colSort)
    }

    private func indexRow(_ i: TableIndexInfo) -> DriverRow {
        DriverRow(columns: idxHeaders, values: [
            "index_name": i.name,
            "index_algorithm": i.algorithm,
            "is_unique": i.unique ? "TRUE" : "FALSE",
            "column_name": i.columns.joined(separator: ", "),
        ])
    }

    private var indexItems: [(Int, DriverRow)] {
        sortItems(Array(session.tableIndexes.enumerated()).map { ($0.offset, indexRow($0.element)) }, idxSort)
    }

    private let triggerHeaders = ["trigger_name", "timing", "event", "statement"]
    @State private var newTriggerOpen = false
    @State private var resetAutoIncOpen = false

    private func triggerRow(_ t: TableTrigger) -> DriverRow {
        DriverRow(columns: triggerHeaders, values: [
            "trigger_name": t.name,
            "timing": t.timing,
            "event": t.event,
            "statement": t.statement,
        ])
    }

    private var triggerItems: [(Int, DriverRow)] {
        let base = Array(session.tableTriggers.enumerated())
            .filter { colSearch.isEmpty || $0.element.name.localizedCaseInsensitiveContains(colSearch) }
            .map { ($0.offset, triggerRow($0.element)) }
        return sortItems(base, trigSort)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            if session.structureLoading && session.tableSchema.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DataGrid.bgRow)
            } else {
                switch session.structureSection {
                case .fields:   fieldsContent
                case .triggers: triggersContent
                case .info:     infoContent
                }
            }
        }
        .task(id: session.activeTabState?.id) {
            if let tab = session.activeTabState { await session.loadStructure(tab.table) }
        }
        .onChange(of: session.structureSection) { _, _ in
            colSearch = ""
            session.clearDetail()
        }
    }

    private var fieldsContent: some View {
        VSplitView {
            AppKitDataGrid(
                columns: colHeaders, rows: columnItems.map { $0.1 },
                dataKey: "col|\(table)|\(session.tableSchema.count)|\(colSearch)|\(colSort?.key ?? "")\(colSort?.asc == true ? 1 : 0)",
                sortColumn: colSort?.key, sortAscending: colSort?.asc ?? true,
                onSelect: { i in
                    if let i, columnItems.indices.contains(i) { session.showColumnDetail(columnItems[i].0) }
                    else { session.clearDetail() }
                },
                onHeaderClick: { c in colSort = cycled(colSort, c); session.clearDetail() }
            )
            .frame(minHeight: 140)
            AppKitDataGrid(
                columns: idxHeaders, rows: indexItems.map { $0.1 },
                dataKey: "idx|\(table)|\(session.tableIndexes.count)|\(idxSort?.key ?? "")\(idxSort?.asc == true ? 1 : 0)",
                sortColumn: idxSort?.key, sortAscending: idxSort?.asc ?? true,
                onSelect: { i in
                    if let i, indexItems.indices.contains(i) { session.showIndexDetail(indexItems[i].0) }
                    else { session.clearDetail() }
                },
                onHeaderClick: { c in idxSort = cycled(idxSort, c); session.clearDetail() }
            )
            .frame(minHeight: 80)
        }
    }

    private var sectionCloseButton: some View {
        Button { session.structureSection = .fields } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(L10n.t("structure.close"))
    }

    private var triggersContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { newTriggerOpen = true } label: {
                    Label(L10n.t("structure.newTrigger"), systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                sectionCloseButton
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DataGrid.bgChrome)

            Divider()

            if session.tableTriggers.isEmpty {
                structureEmpty(L10n.t("structure.noTriggers"))
            } else {
                AppKitDataGrid(
                    columns: triggerHeaders, rows: triggerItems.map { $0.1 },
                    dataKey: "trg|\(table)|\(session.tableTriggers.count)|\(colSearch)|\(trigSort?.key ?? "")\(trigSort?.asc == true ? 1 : 0)",
                    sortColumn: trigSort?.key, sortAscending: trigSort?.asc ?? true,
                    onSelect: { i in
                        if let i, triggerItems.indices.contains(i) { session.showTriggerDetail(triggerItems[i].0) }
                        else { session.clearDetail() }
                    },
                    onHeaderClick: { c in trigSort = cycled(trigSort, c); session.clearDetail() }
                )
            }
        }
        .sheet(isPresented: $newTriggerOpen) {
            NewTriggerSheet(table: table) { newTriggerOpen = false }
        }
    }

    @ViewBuilder private var infoContent: some View {
        if session.tableInfo == nil && (session.tableDDL?.isEmpty ?? true) {
            structureEmpty(L10n.t("structure.noInfo"))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    sectionCloseButton
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(DataGrid.bgChrome)

                Divider()

                HSplitView {
                    infoMetaPane.frame(minWidth: 150, idealWidth: 175, maxWidth: 280)
                    infoDDLPane.frame(minWidth: 400)
                }
                Divider()
                infoStatusBar
            }
            .sheet(isPresented: $resetAutoIncOpen) {
                ResetAutoIncrementSheet(current: session.tableInfo?.autoIncrement ?? "") {
                    resetAutoIncOpen = false
                }
            }
        }
    }

    private var infoStatusBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L10n.t("structure.resetAutoInc")) { resetAutoIncOpen = true }
                    .disabled(session.tableInfo?.autoIncrement == nil)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .foregroundStyle(.secondary)

            Spacer()
            Text(infoSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(DataGrid.bgChrome)
    }

    private var infoSummary: String {
        guard let i = session.tableInfo else { return "" }
        var parts: [String] = []
        if let a = i.autoIncrement, !a.isEmpty { parts.append("\(L10n.t("structure.sumAutoInc")) \(a)") }
        if let r = i.rows, let n = Int(r) {
            let f = NumberFormatter(); f.numberStyle = .decimal
            parts.append("\(L10n.t("structure.sumRows")) \(f.string(from: NSNumber(value: n)) ?? r)")
        }
        if let c = i.createTime, !c.isEmpty { parts.append("\(L10n.t("structure.sumCreated")) \(c)") }
        return parts.joined(separator: "  |  ")
    }

    private var infoMetaPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let info = session.tableInfo {
                    ForEach(infoPairs(info), id: \.0) { pair in
                        infoRow(label: pair.0, value: pair.1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DataGrid.bgRow)
    }

    private var infoDDLPane: some View {
        SQLHighlightView(text: session.tableDDL ?? "")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoPairs(_ i: TableInfo) -> [(String, String?)] {
        [
            ("structure.info.engine", i.engine),
            ("structure.info.rowFormat", i.rowFormat),
            ("structure.info.rows", i.rows),
            ("structure.info.dataLength", Self.formatBytes(i.dataLength)),
            ("structure.info.indexLength", Self.formatBytes(i.indexLength)),
            ("structure.info.autoIncrement", i.autoIncrement),
            ("structure.info.collation", i.collation),
            ("structure.info.createTime", i.createTime),
            ("structure.info.updateTime", i.updateTime),
            ("structure.info.comment", i.comment),
        ].map { (L10n.t($0.0), $0.1) }
    }

    private static func formatBytes(_ raw: String?) -> String? {
        guard let raw, let n = Int64(raw) else { return raw }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func infoRow(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Group {
                if let v = value, !v.isEmpty {
                    Text(v).font(.system(size: 12)).foregroundStyle(.primary).textSelection(.enabled)
                } else {
                    Text(value == nil ? "NULL" : "EMPTY").font(.system(size: 11).italic()).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        }
    }

    private func structureEmpty(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(msg).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DataGrid.bgRow)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(L10n.t("structure.name"))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            fieldBox(focused: false) {
                Text(table)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }
            .frame(width: 220)

            Text(L10n.t("structure.primary"))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .padding(.leading, 6)
            fieldBox(focused: false) {
                ForEach(pkColumns, id: \.self) { col in
                    Text(col)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Self.focusRing))
                }
            }
            .frame(maxWidth: .infinity)

            fieldBox(focused: searchFocused) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L10n.t(session.structureSection == .triggers ? "structure.searchTrigger" : "structure.searchColumn"), text: $colSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .frame(maxWidth: .infinity)
                if !colSearch.isEmpty {
                    Button { colSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 220)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DataGrid.bgChrome)
    }

    private func fieldBox<Content: View>(focused: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? Self.focusRing : Color.white.opacity(0.14),
                        lineWidth: focused ? 2 : 1)
        )
    }

    static let focusRing = Color(red: 0.00, green: 0.46, blue: 0.56)
}

// MARK: - NewTriggerSheet

struct NewTriggerSheet: View {
    @Environment(SessionStore.self) private var session
    let table: String
    var onClose: () -> Void

    @State private var sql: String = ""
    @State private var errorMsg: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("structure.newTrigger"))
                .font(.system(size: 14, weight: .semibold))

            TextEditor(text: $sql)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 520, minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))

            if let e = errorMsg {
                Text(e)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(L10n.t("form.cancel"), action: onClose)
                Button(L10n.t("structure.create")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(running || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 600)
        .onAppear {
            let t = table.replacingOccurrences(of: "`", with: "``")
            sql = """
            CREATE TRIGGER `trg_\(table)_ai`
            AFTER INSERT ON `\(t)`
            FOR EACH ROW
            BEGIN
              -- statement
            END
            """
        }
    }

    private func create() {
        running = true
        errorMsg = nil
        Task {
            let err = await session.executeTrigger(sql)
            running = false
            if let err { errorMsg = err } else { onClose() }
        }
    }
}

// MARK: - ResetAutoIncrementSheet

struct ResetAutoIncrementSheet: View {
    @Environment(SessionStore.self) private var session
    let current: String
    var onClose: () -> Void

    @State private var value: String = ""
    @State private var errorMsg: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("structure.resetAutoInc"))
                .font(.system(size: 14, weight: .semibold))

            HStack {
                Text(L10n.t("structure.info.autoIncrement"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            if let e = errorMsg {
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(L10n.t("form.cancel"), action: onClose)
                Button(L10n.t("structure.reset")) { reset() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(running || Int64(value.trimmingCharacters(in: .whitespaces)) == nil)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { value = current }
    }

    private func reset() {
        running = true
        errorMsg = nil
        Task {
            let err = await session.resetAutoIncrement(value)
            running = false
            if let err { errorMsg = err } else { onClose() }
        }
    }
}

// MARK: - DataGrid

struct DataGrid: View {
    let columns: [String]
    let rows: [DriverRow]
    @Binding var selectedRowIndex: Int?

    @State private var colWidths: [String: CGFloat] = [:]
    @State private var resizing: (col: String, startWidth: CGFloat)?
    @State private var cachedNumericCols: Set<String> = []
    @State private var cachedForColumns: [String] = []

    private let rowH: CGFloat = 26
    private let headerH: CGFloat = 28
    private let indexColW: CGFloat = 44

    // Sampled directly from TablePlus screenshot.
    static let bgRow      = Color(red: 30/255, green: 30/255, blue: 30/255)
    static let bgRowAlt   = Color(red: 41/255, green: 41/255, blue: 41/255)
    static let bgHeader   = Color(red: 30/255, green: 30/255, blue: 30/255)
    static let bgChrome   = Color(red: 30/255, green: 30/255, blue: 30/255)

    private var gridBackground: Color { Self.bgRow }
    private var headerBackground: Color { Self.bgHeader }
    private var rowA: Color { Self.bgRow }
    private var rowB: Color { Self.bgRowAlt }
    private var separator: Color { Color.white.opacity(0.06) }
    private var headerSeparator: Color { Color.white.opacity(0.18) }
    private var cellSeparator: Color { Color.white.opacity(0.05) }
    private var numericCols: Set<String> { cachedNumericCols }

    private func recomputeNumericCols() {
        var set: Set<String> = []
        for col in columns {
            for r in rows.prefix(20) {
                if let v = r.string(col), !v.isEmpty {
                    if Int(v) != nil || Double(v) != nil {
                        set.insert(col)
                    }
                    break
                }
            }
        }
        cachedNumericCols = set
        cachedForColumns = columns
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0) {
                headerRow
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    rowView(idx: idx, row: row)
                }
            }
        }
        .background(gridBackground)
        .transaction { $0.animation = nil }   // kill implicit animations during drag
        .onAppear { recomputeNumericCols() }
        .onChange(of: columns) { _, _ in recomputeNumericCols() }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { col in
                cellHeader(col, width: width(for: col), alignment: .leading, col: col)
            }
        }
        .frame(height: headerH)
        .background(headerBackground)
        .overlay(Rectangle().fill(separator).frame(height: 1), alignment: .bottom)
    }

    private func rowView(idx: Int, row: DriverRow) -> some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { col in
                cellValue(row.string(col),
                          width: width(for: col),
                          numeric: numericCols.contains(col))
            }
        }
        .frame(height: rowH)
        .background(
            selectedRowIndex == idx
                ? Color.accentColor.opacity(0.32)
                : (idx % 2 == 0 ? rowA : rowB)
        )
        .overlay(Rectangle().fill(separator).frame(height: 1), alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { selectedRowIndex = idx }
    }

    private func cellHeader(_ text: String, width: CGFloat, alignment: Alignment, col: String? = nil) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: width, height: headerH, alignment: alignment)
            .overlay(alignment: .trailing) {
                if let col = col {
                    ZStack(alignment: .trailing) {
                        Rectangle()
                            .fill(headerSeparator)
                            .frame(width: 1, height: headerH - 12)
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if resizing?.col != col {
                                            resizing = (col, self.width(for: col))
                                        }
                                        let newW = max(50, resizing!.startWidth + value.translation.width)
                                        var tx = Transaction()
                                        tx.disablesAnimations = true
                                        withTransaction(tx) {
                                            colWidths[col] = newW
                                        }
                                    }
                                    .onEnded { _ in resizing = nil }
                            )
                    }
                } else {
                    Rectangle().fill(headerSeparator).frame(width: 1, height: headerH - 12)
                }
            }
    }

    private func cellIndex(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .frame(width: indexColW, height: rowH, alignment: .trailing)
    }

    private func cellValue(_ value: String?, width: CGFloat, numeric: Bool) -> some View {
        Group {
            if let v = value {
                Text(v)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("NULL")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: rowH, alignment: numeric ? .trailing : .leading)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(cellSeparator)
                .frame(width: 1, height: rowH - 8)  // partial height, not full
        }
    }

    private func width(for col: String) -> CGFloat {
        colWidths[col] ?? 150
    }
}
