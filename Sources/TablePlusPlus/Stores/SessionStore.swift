import Foundation
import Observation
import GRDB
import AppKit

struct SessionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum FilterOp: String, CaseIterable, Identifiable {
    case eq, neq, gt, lt, gte, lte, like, notLike, isNull, notNull
    var id: String { rawValue }
    var label: String {
        switch self {
        case .eq: "="
        case .neq: "≠"
        case .gt: ">"
        case .lt: "<"
        case .gte: "≥"
        case .lte: "≤"
        case .like: "LIKE"
        case .notLike: "NOT LIKE"
        case .isNull: "IS NULL"
        case .notNull: "IS NOT NULL"
        }
    }
    var sqlOperator: String {
        switch self {
        case .eq: "="
        case .neq: "<>"
        case .gt: ">"
        case .lt: "<"
        case .gte: ">="
        case .lte: "<="
        case .like: "LIKE"
        case .notLike: "NOT LIKE"
        case .isNull: "IS NULL"
        case .notNull: "IS NOT NULL"
        }
    }
    var needsValue: Bool { self != .isNull && self != .notNull }
}

struct FilterCondition: Identifiable, Equatable {
    let id = UUID()
    var column: String = ""
    var op: FilterOp = .eq
    var value: String = ""

    var isValid: Bool {
        guard !column.isEmpty else { return false }
        return op.needsValue ? !value.isEmpty : true
    }

    var sql: String {
        let col = "`\(column.replacingOccurrences(of: "`", with: "``"))`"
        guard op.needsValue else { return "\(col) \(op.sqlOperator)" }
        let v = value.replacingOccurrences(of: "'", with: "''")
        return "\(col) \(op.sqlOperator) '\(v)'"
    }
}

struct SortSpec: Equatable {
    var column: String
    var ascending: Bool
}

/// One field shown in the right-side detail panel. Any grid row maps to a list of these.
struct DetailField: Identifiable {
    let id: String
    let label: String
    let value: String?
    var isKey: Bool = false
    var tag: String? = nil
    init(_ label: String, _ value: String?, isKey: Bool = false, tag: String? = nil) {
        self.id = label
        self.label = label
        self.value = value
        self.isKey = isKey
        self.tag = tag
    }
}

/// One uncommitted cell edit in the current page. `newValue` nil ⇒ SQL NULL.
struct CellEdit {
    let row: Int          // index into tableRows (current page)
    let column: String
    var newValue: String?
    let table: String     // table the row belongs to; guards stale writes across reloads
}

/// One uncommitted new row. `values[col]` nil ⇒ SQL NULL; absent key ⇒ column omitted (DB DEFAULT).
struct InsertDraft: Identifiable {
    let id = UUID()
    var values: [String: String?] = [:]
}

/// Stable identity of a displayed grid row — survives the index shift between data rows and
/// insert drafts. Resolves stale-index bugs across detail / copy / delete / multi-select.
/// Result of one executed statement in the SQL console (one "Query N" page).
struct QueryPage: Identifiable {
    let id = UUID()
    let sql: String
    var columns: [String] = []
    var rows: [DriverRow] = []
    var rowsAffected: Int?       // non-SELECT statements
    var message: String?
    var error: String?
    var running: Bool = false
    var elapsed: Double = 0      // seconds, ticks while running then frozen

    // Single-table editability — filled only when the result maps to one updatable table whose
    // key columns are present in the projection. Empty ⇒ read-only result.
    var editTable: String?
    var editDatabase: String?
    var editRowKey: [String] = []           // unique-key columns used to target a row
    var editColumns: Set<String> = []        // real table columns present in the result (editable set)
    var queryEdits: [String: String?] = [:]  // "row|column" → new value (inner nil ⇒ SQL NULL)
    var editsVersion: Int = 0
    var committingEdits: Bool = false

    var rowCount: Int { columns.isEmpty ? (rowsAffected ?? 0) : rows.count }
    var isEditable: Bool { editTable != nil }
    var hasQueryEdits: Bool { !queryEdits.isEmpty }
}

/// Thread-safe collector for a streaming query. The driver appends batches off the event loop;
/// the main actor drains them into the page on a throttle. `@unchecked Sendable` — guarded by lock.
final class RowSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [DriverRow] = []
    private var cols: [String] = []
    private var colsReady = false
    private var _total = 0
    private var _done = false
    private var _error: String?

    func setColumns(_ c: [String]) { lock.lock(); if !colsReady { cols = c; colsReady = true }; lock.unlock() }
    func append(_ rows: [DriverRow]) { lock.lock(); pending.append(contentsOf: rows); _total += rows.count; lock.unlock() }
    func complete(error: String?) { lock.lock(); _done = true; _error = error; lock.unlock() }

    /// Returns columns (if newly known) + the rows accumulated since the last drain.
    func drain() -> (columns: [String]?, rows: [DriverRow], total: Int, done: Bool, error: String?) {
        lock.lock(); defer { lock.unlock() }
        let delta = pending; pending = []
        return (colsReady ? cols : nil, delta, _total, _done, _error)
    }
}

enum GridRowKind: Hashable {
    case existing(Int)    // index into tableRows
    case insert(UUID)     // insertDrafts id
}

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    var driver: (any DatabaseDriver)?
    var profile: ConnectionProfile?
    var serverInfo: String?
    var databases: [String] = []
    var loading: Bool = false
    var isReconnecting: Bool = false
    var error: String?
    var restoredTable: String?  // last-viewed table to be picked up by WorkspaceView on open

    // Open databases (left rail) + the active one. Each DatabaseContext keeps its own object
    // lists, open table tabs, and SQL-editor state; switching the rail just swaps `activeDatabase`.
    var contexts: [DatabaseContext] = []
    var activeDatabase: String?
    private var driverDatabase: String?   // which db the driver's connection has USE'd (lazy)
    // Connection-level scratch console used when no database is open (database == ""): queries run
    // without a USE, so the editor is always writable. In-memory only, not persisted.
    var scratchContext: DatabaseContext?

    var activeContext: DatabaseContext? { contexts.first { $0.database == activeDatabase } ?? scratchContext }
    var activeTabState: TableTabState? { activeContext?.activeTab }

    // MARK: Facades — the flat names views/methods still use, forwarded to the active context/tab.
    var currentDatabase: String? { activeDatabase }

    var tables: [String] {
        get { activeContext?.tables ?? [] }
        set { activeContext?.tables = newValue }
    }
    var views: [String] {
        get { activeContext?.views ?? [] }
        set { activeContext?.views = newValue }
    }
    var functions: [String] {
        get { activeContext?.functions ?? [] }
        set { activeContext?.functions = newValue }
    }
    var procedures: [String] {
        get { activeContext?.procedures ?? [] }
        set { activeContext?.procedures = newValue }
    }
    var recent: [String] {
        get { activeContext?.recent ?? [] }
        set { activeContext?.recent = newValue }
    }
    var openTabs: [String] { activeContext?.tabs.map(\.table) ?? [] }
    var activeTab: String? { activeTabState?.table }

    var currentTable: String? { activeTabState?.table }
    var tableColumns: [String] {
        get { activeTabState?.tableColumns ?? [] }
        set { activeTabState?.tableColumns = newValue }
    }
    var tablePrimaryKeys: Set<String> {
        get { activeTabState?.tablePrimaryKeys ?? [] }
        set { activeTabState?.tablePrimaryKeys = newValue }
    }
    var tableRowKey: [String] {
        get { activeTabState?.tableRowKey ?? [] }
        set { activeTabState?.tableRowKey = newValue }
    }
    var tableRows: [DriverRow] {
        get { activeTabState?.tableRows ?? [] }
        set { activeTabState?.tableRows = newValue }
    }
    var tableOffset: Int {
        get { activeTabState?.tableOffset ?? 0 }
        set { activeTabState?.tableOffset = newValue }
    }
    var tablePageSize: Int {
        get { activeTabState?.tablePageSize ?? 300 }
        set { activeTabState?.tablePageSize = newValue }
    }
    var tableTotal: Int? {
        get { activeTabState?.tableTotal }
        set { activeTabState?.tableTotal = newValue }
    }
    var tableLoading: Bool {
        get { activeTabState?.tableLoading ?? false }
        set { activeTabState?.tableLoading = newValue }
    }

    var edits: [String: CellEdit] {
        get { activeTabState?.edits ?? [:] }
        set { activeTabState?.edits = newValue }
    }
    var insertDrafts: [InsertDraft] {
        get { activeTabState?.insertDrafts ?? [] }
        set { activeTabState?.insertDrafts = newValue }
    }
    var deletedRows: Set<Int> {
        get { activeTabState?.deletedRows ?? [] }
        set { activeTabState?.deletedRows = newValue }
    }
    var editsVersion: Int {
        get { activeTabState?.editsVersion ?? 0 }
        set { activeTabState?.editsVersion = newValue }
    }
    var showEditSQL: Bool {
        get { activeTabState?.showEditSQL ?? false }
        set { activeTabState?.showEditSQL = newValue }
    }
    var committing: Bool {
        get { activeTabState?.committing ?? false }
        set { activeTabState?.committing = newValue }
    }
    var hasEdits: Bool { !edits.isEmpty || !insertDrafts.isEmpty || !deletedRows.isEmpty }
    var draftCount: Int { edits.count + insertDrafts.count + deletedRows.count }

    var focusToken: Int {
        get { activeTabState?.focusToken ?? 0 }
        set { activeTabState?.focusToken = newValue }
    }
    var focusGridRow: Int? {
        get { activeTabState?.focusGridRow }
        set { activeTabState?.focusGridRow = newValue }
    }

    /// True when this grid-row index is marked for deletion (red highlight).
    func isRowDeleted(_ index: Int) -> Bool {
        if case .existing(let r) = gridRowKind(at: index) { return deletedRows.contains(r) }
        return false
    }

    /// Rows shown in the data grid: committed rows followed by uncommitted insert drafts.
    var gridRows: [DriverRow] {
        guard !insertDrafts.isEmpty else { return tableRows }
        let cols = gridColumnTemplate
        let drafts = insertDrafts.map { draft -> DriverRow in
            let cells = cols.map { c -> DriverCell in
                guard let v = draft.values[c.name] else { return .text("") }   // unset ⇒ DB default (shows EMPTY, not NULL)
                return v.map { DriverCell.text($0) } ?? .null                  // explicit Set NULL ⇒ NULL
            }
            return DriverRow(columns: cols, cells: cells)
        }
        return tableRows + drafts
    }

    private var gridColumnTemplate: [DriverColumn] {
        tableRows.first?.columns ?? tableColumns.map { DriverColumn(name: $0) }
    }

    /// Stable identity for a displayed grid-row index.
    func gridRowKind(at index: Int) -> GridRowKind? {
        if index < tableRows.count { return .existing(index) }
        let di = index - tableRows.count
        guard insertDrafts.indices.contains(di) else { return nil }
        return .insert(insertDrafts[di].id)
    }

    // View state for the active tab (filters / sort / column visibility)
    var allTableColumns: [String] {
        get { activeTabState?.allTableColumns ?? [] }
        set { activeTabState?.allTableColumns = newValue }
    }
    var hiddenColumns: Set<String> {
        get { activeTabState?.hiddenColumns ?? [] }
        set { activeTabState?.hiddenColumns = newValue }
    }
    var filters: [FilterCondition] {
        get { activeTabState?.filters ?? [] }
        set { activeTabState?.filters = newValue }
    }
    var orderBy: [SortSpec] {
        get { activeTabState?.orderBy ?? [] }
        set { activeTabState?.orderBy = newValue }
    }
    var whereText: String {
        get { activeTabState?.whereText ?? "" }
        set { activeTabState?.whereText = newValue }
    }
    var orderByText: String {
        get { activeTabState?.orderByText ?? "" }
        set { activeTabState?.orderByText = newValue }
    }

    // Column metadata for the active tab's data (loaded once per table switch).
    var dataSchema: [TableColumnInfo] {
        get { activeTabState?.dataSchema ?? [] }
        set { activeTabState?.dataSchema = newValue }
    }
    var loadToken: Int {
        get { activeTabState?.loadToken ?? 0 }
        set { activeTabState?.loadToken = newValue }
    }

    /// Columns a user must not hand-fill in an insert draft (DB computes / generates them).
    var insertSkipColumns: Set<String> {
        Set(dataSchema.filter {
            let e = $0.extra.lowercased()
            return e.contains("auto_increment") || e.contains("generated")
                || e.contains("virtual") || e.contains("stored")
                || $0.type.lowercased().hasPrefix("bit")
        }.map(\.name))
    }

    /// Numeric by declared column type (the data SELECT keeps DECIMAL/FLOAT as text cells).
    private func columnIsNumeric(_ name: String) -> Bool {
        if let c = tableRows.first?.columns.first(where: { $0.name == name }), c.isNumeric { return true }
        guard let t = dataSchema.first(where: { $0.name == name })?.type.lowercased() else { return false }
        return ["int", "tinyint", "smallint", "mediumint", "bigint", "decimal", "numeric",
                "float", "double", "real", "year"].contains { t.hasPrefix($0) }
    }

    // Structure view (per active tab)
    enum StructureSection { case fields, triggers, info }
    var structureSection: StructureSection {
        get { activeTabState?.structureSection ?? .fields }
        set { activeTabState?.structureSection = newValue }
    }
    var tableSchema: [TableColumnInfo] {
        get { activeTabState?.tableSchema ?? [] }
        set { activeTabState?.tableSchema = newValue }
    }
    var tableIndexes: [TableIndexInfo] {
        get { activeTabState?.tableIndexes ?? [] }
        set { activeTabState?.tableIndexes = newValue }
    }
    var tableTriggers: [TableTrigger] {
        get { activeTabState?.tableTriggers ?? [] }
        set { activeTabState?.tableTriggers = newValue }
    }
    var tableDDL: String? {
        get { activeTabState?.tableDDL }
        set { activeTabState?.tableDDL = newValue }
    }
    var tableInfo: TableInfo? {
        get { activeTabState?.tableInfo }
        set { activeTabState?.tableInfo = newValue }
    }
    var structureLoading: Bool {
        get { activeTabState?.structureLoading ?? false }
        set { activeTabState?.structureLoading = newValue }
    }
    var structureTable: String? {
        get { activeTabState?.structureTable }
        set { activeTabState?.structureTable = newValue }
    }

    // Which viewer tab is active + selected structure column (per active tab)
    enum ViewerMode { case data, structure }
    var viewerMode: ViewerMode {
        get { activeTabState?.viewerMode ?? .data }
        set { activeTabState?.viewerMode = newValue }
    }
    var structureSelectedColumn: Int? {
        get { activeTabState?.structureSelectedColumn }
        set { activeTabState?.structureSelectedColumn = newValue }
    }

    // Right-panel detail — transient UI, cleared on tab/context/mode switch.
    var detailFields: [DetailField] = []
    var detailEditableRow: Int?   // grid-row index when the detail shows an editable data row
    var detailIsQuery = false     // detail edits route to the active query page, not the table tab
    var queryFocusToken = 0       // bump + queryFocusRow ⇒ scroll the result grid to that row
    var queryFocusRow: Int?

    // Console log (executed SQL with timestamps)
    struct ConsoleEntry: Identifiable { let id = UUID(); let time: String; let sql: String }
    var consoleLog: [ConsoleEntry] = []
    private static let logFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    func logSQL(_ sql: String) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        consoleLog.append(ConsoleEntry(time: Self.logFmt.string(from: Date()), sql: trimmed))
        if consoleLog.count > 500 { consoleLog.removeFirst(consoleLog.count - 500) }
    }

    var consoleText: String {
        consoleLog.map { "-- \($0.time)\n\($0.sql)\($0.sql.hasSuffix(";") ? "" : ";")" }
            .joined(separator: "\n\n")
    }

    // SQL query tabs (per active context) + history (connection-level)
    var queryTabs: [QueryTabState] { activeContext?.queryTabs ?? [] }
    var activeQueryTabID: UUID? { activeContext?.activeQueryTabID }
    /// Any tab anywhere mid-run — gates the Run buttons so concurrent runs can't collide on the
    /// single shared connection.
    var anyQueryRunning: Bool { contexts.contains { ctx in ctx.queryTabs.contains { $0.queryRunning } } }

    var editorSQL: String {
        get { activeContext?.activeQueryTab?.editorSQL ?? "" }
        set { activeContext?.activeQueryTab?.editorSQL = newValue }
    }
    var queryPages: [QueryPage] {
        get { activeContext?.activeQueryTab?.queryPages ?? [] }
        set { activeContext?.activeQueryTab?.queryPages = newValue }
    }
    var activeQueryPage: Int {
        get { activeContext?.activeQueryTab?.activeQueryPage ?? 0 }
        set { activeContext?.activeQueryTab?.activeQueryPage = newValue }
    }
    var currentQueryPage: QueryPage? {
        let pages = queryPages
        return pages.indices.contains(activeQueryPage) ? pages[activeQueryPage] : pages.last
    }
    var queryColumns: [String] { currentQueryPage?.columns ?? [] }
    var queryRows: [DriverRow] { currentQueryPage?.rows ?? [] }
    var queryRunning: Bool {
        get { activeContext?.activeQueryTab?.queryRunning ?? false }
        set { activeContext?.activeQueryTab?.queryRunning = newValue }
    }
    /// nil ⇒ run SELECTs as written; else append LIMIT n to SELECTs without one.
    var queryLimit: Int?
    /// Statement progress of a running batch (e.g. "1/3").
    var queryProgress: (done: Int, total: Int) = (0, 0)
    var history: [QueryHistoryRecord] = []
    var savedQueries: [SavedQueryRecord] = []

    // MARK: - Saved queries (bound to connection, shown in the Queries sidebar)

    func loadSavedQueries() {
        guard let pid = profile?.id.uuidString else { savedQueries = []; return }
        savedQueries = Persistence.loadSavedQueries(connID: pid, database: activeContext?.database ?? "")
    }

    func saveQuery(name: String, sql: String) {
        guard let pid = profile?.id.uuidString else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = Persistence.insertSavedQuery(connID: pid, database: activeContext?.database ?? "",
                                         name: trimmed, sql: sql)
        loadSavedQueries()
    }

    func deleteSavedQuery(_ rec: SavedQueryRecord) {
        guard let id = rec.id else { return }
        Persistence.deleteSavedQuery(id: id)
        loadSavedQueries()
    }

    /// Open a saved query into a fresh query tab named after it.
    func openSavedQuery(_ rec: SavedQueryRecord) {
        guard let ctx = activeContext else { return }
        persistQueryTab(ctx.activeQueryTab, ctx: ctx)
        let t = QueryTabState(name: rec.name)
        t.editorSQL = rec.sql
        ctx.queryTabs.append(t)
        ctx.activeQueryTabID = t.id
        persistQueryTab(t, ctx: ctx)
        clearDetail()
    }

    // MARK: - Query tab management (bound to connection + database, persisted to SQLite)

    func addQueryTab() {
        guard let ctx = activeContext else { return }
        persistQueryTab(ctx.activeQueryTab, ctx: ctx)   // flush the outgoing tab's SQL
        let t = QueryTabState(name: nextQueryTabName(ctx))
        ctx.queryTabs.append(t)
        ctx.activeQueryTabID = t.id
        clearDetail()
        persistQueryTab(t, ctx: ctx)
    }

    func selectQueryTab(_ id: UUID) {
        guard let ctx = activeContext, ctx.activeQueryTabID != id else { return }
        persistQueryTab(ctx.activeQueryTab, ctx: ctx)
        ctx.activeQueryTabID = id
        clearDetail()
    }

    func closeQueryTab(_ id: UUID) {
        guard let ctx = activeContext,
              let idx = ctx.queryTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = ctx.queryTabs[idx]
        guard !tab.queryRunning else { return }   // don't yank a running tab
        deleteQueryTab(tab)
        ctx.queryTabs.remove(at: idx)
        if ctx.activeQueryTabID == id {
            ctx.activeQueryTabID = (ctx.queryTabs.indices.contains(idx) ? ctx.queryTabs[idx] : ctx.queryTabs.last)?.id
        }
        clearDetail()
    }

    func closeAllQueryTabs() {
        guard let ctx = activeContext else { return }
        for t in ctx.queryTabs where !t.queryRunning { deleteQueryTab(t) }
        ctx.queryTabs.removeAll { !$0.queryRunning }
        ctx.activeQueryTabID = ctx.queryTabs.first?.id
        clearDetail()
    }

    func selectAdjacentQueryTab(_ delta: Int) {
        guard let ctx = activeContext,
              let idx = ctx.queryTabs.firstIndex(where: { $0.id == ctx.activeQueryTabID }) else { return }
        let target = idx + delta
        guard ctx.queryTabs.indices.contains(target) else { return }
        selectQueryTab(ctx.queryTabs[target].id)
    }

    func closeOtherQueryTabs(_ id: UUID) {
        guard let ctx = activeContext else { return }
        for t in ctx.queryTabs where t.id != id { closeQueryTab(t.id) }
    }

    func closeQueryTabsToLeft(_ id: UUID) {
        guard let ctx = activeContext,
              let idx = ctx.queryTabs.firstIndex(where: { $0.id == id }) else { return }
        for t in ctx.queryTabs.prefix(idx) { closeQueryTab(t.id) }
    }

    func closeQueryTabsToRight(_ id: UUID) {
        guard let ctx = activeContext,
              let idx = ctx.queryTabs.firstIndex(where: { $0.id == id }) else { return }
        for t in ctx.queryTabs.suffix(from: idx + 1) { closeQueryTab(t.id) }
    }

    func renameQueryTab(_ id: UUID, name: String) {
        guard let ctx = activeContext, let t = ctx.queryTabs.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        t.name = trimmed
        persistQueryTab(t, ctx: ctx)
    }

    private func nextQueryTabName(_ ctx: DatabaseContext) -> String {
        var maxN = 0
        for t in ctx.queryTabs {
            if t.name.hasPrefix("Query "), let n = Int(t.name.dropFirst(6)) { maxN = max(maxN, n) }
        }
        return "Query \(max(maxN + 1, ctx.queryTabs.count + 1))"
    }

    func persistActiveQueryTab() {
        guard let ctx = activeContext else { return }
        persistQueryTab(ctx.activeQueryTab, ctx: ctx)
    }

    private func persistQueryTab(_ tab: QueryTabState?, ctx: DatabaseContext) {
        guard let tab, !ctx.database.isEmpty, let pid = profile?.id.uuidString else { return }
        let pos = ctx.queryTabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        tab.persistID = Persistence.upsertQueryTab(id: tab.persistID, connID: pid, database: ctx.database,
                                                   name: tab.name, sql: tab.editorSQL, position: pos)
    }

    private func deleteQueryTab(_ tab: QueryTabState) {
        if let pid = tab.persistID { Persistence.deleteQueryTab(id: pid) }
    }

    private func restoreQueryTabs(for ctx: DatabaseContext) {
        guard let pid = profile?.id.uuidString else { return }
        let saved = Persistence.loadQueryTabs(connID: pid, database: ctx.database)
        guard !saved.isEmpty else { return }   // keep the default tab seeded by DatabaseContext.init
        ctx.queryTabs = saved.map { QueryTabState(name: $0.name, persistID: $0.id, sql: $0.sql) }
        ctx.activeQueryTabID = ctx.queryTabs.first?.id
    }

    func openInTab(_ name: String) {
        guard let ctx = activeContext else { return }
        let tab = ctx.tab(forTable: name) ?? {
            let t = TableTabState(database: ctx.database, table: name)
            ctx.tabs.append(t)
            return t
        }()
        ctx.activeTabID = tab.id
        tab.viewerMode = .data
        clearDetail()
        persistTabs()
    }

    func selectTab(_ name: String) {
        guard let ctx = activeContext, let tab = ctx.tab(forTable: name) else { return }
        ctx.activeTabID = tab.id
        clearDetail()
        persistTabs()
    }

    func closeTab(_ name: String) {
        guard let ctx = activeContext, let idx = ctx.tabs.firstIndex(where: { $0.table == name }) else { return }
        let wasActive = ctx.activeTab?.table == name
        ctx.tabs.remove(at: idx)
        if wasActive {
            ctx.activeTabID = (ctx.tabs.indices.contains(idx) ? ctx.tabs[idx] : ctx.tabs.last)?.id
            clearDetail()
        }
        persistTabs()
    }

    func closeActiveTab() {
        if let t = activeTab { closeTab(t) }
    }

    func closeOtherTabs(_ name: String) {
        guard let ctx = activeContext else { return }
        ctx.tabs.removeAll { $0.table != name }
        ensureActiveTab(ctx, keep: name)
        persistTabs()
    }

    func closeTabsToLeft(_ name: String) {
        guard let ctx = activeContext, let idx = ctx.tabs.firstIndex(where: { $0.table == name }), idx > 0 else { return }
        ctx.tabs.removeSubrange(0..<idx)
        ensureActiveTab(ctx, keep: name)
        persistTabs()
    }

    func closeTabsToRight(_ name: String) {
        guard let ctx = activeContext, let idx = ctx.tabs.firstIndex(where: { $0.table == name }), idx < ctx.tabs.count - 1 else { return }
        ctx.tabs.removeSubrange((idx + 1)...)
        ensureActiveTab(ctx, keep: name)
        persistTabs()
    }

    func closeAllTabs() {
        guard let ctx = activeContext else { return }
        ctx.tabs.removeAll()
        ctx.activeTabID = nil
        clearDetail()
        persistTabs()
    }

    /// After bulk-closing tabs, keep `name`'s tab active if the previous active one was removed.
    private func ensureActiveTab(_ ctx: DatabaseContext, keep name: String) {
        if !ctx.tabs.contains(where: { $0.id == ctx.activeTabID }) {
            ctx.activeTabID = ctx.tab(forTable: name)?.id ?? ctx.tabs.first?.id
            clearDetail()
        }
    }

    func selectAdjacentTab(_ delta: Int) {
        guard let ctx = activeContext, let cur = ctx.activeTab,
              let idx = ctx.tabs.firstIndex(where: { $0.id == cur.id }) else { return }
        let next = idx + delta
        guard ctx.tabs.indices.contains(next) else { return }
        ctx.activeTabID = ctx.tabs[next].id
        clearDetail()
        persistTabs()
    }

    private func persistTabs() {
        guard let id = profile?.id, let ctx = activeContext else { return }
        PrefsStore.shared.setOpenTabs(connID: id, database: ctx.database,
                                      tabs: ctx.tabs.map(\.table), active: ctx.activeTab?.table)
    }

    private func restoreTabs(for ctx: DatabaseContext) {
        guard let id = profile?.id else { return }
        let saved = PrefsStore.shared.openTabs(connID: id, database: ctx.database)
        let valid = saved.tabs.filter { ctx.tables.contains($0) || ctx.views.contains($0) }
        ctx.tabs = valid.map { TableTabState(database: ctx.database, table: $0) }
        let activeName = saved.active.flatMap { valid.contains($0) ? $0 : valid.first } ?? valid.first
        ctx.activeTabID = activeName.flatMap { ctx.tab(forTable: $0)?.id }
    }

    func touchRecent(_ name: String) {
        guard let pid = profile?.id.uuidString, let db = currentDatabase else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try? Persistence.shared.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO recent_objects (connection_id, database, object_name, opened_at)
                VALUES (?, ?, ?, ?)
            """, arguments: [pid, db, name, now])
        }
        loadRecent()
    }

    private func loadRecent() {
        guard let pid = profile?.id.uuidString, let db = currentDatabase else { recent = []; return }
        let rows = (try? Persistence.shared.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT object_name FROM recent_objects
                WHERE connection_id = ? AND database = ?
                ORDER BY opened_at DESC LIMIT 10
            """, arguments: [pid, db])
        }) ?? []
        recent = rows.compactMap { $0["object_name"] as String? }
    }

    /// SwiftUI convenience: do we currently have an open session?
    var isConnected: Bool { driver != nil }
    /// Backward-compat alias used in some Views; prefer `isConnected`.
    var connection: Any? { driver }

    func open(profile: ConnectionProfile, password: String) async throws {
        loading = true
        defer { loading = false }
        // Close any existing driver before replacing it: MySQLConnection asserts in deinit if the
        // underlying connection was never closed, and close() is async so it can't run from deinit.
        if let old = driver {
            driver = nil
            try? await old.close()
        }
        let d = try await DriverRegistry.open(profile: profile, password: password)
        self.driver = d
        self.profile = profile
        self.serverInfo = try? await d.serverVersion()
        self.databases = (try? await d.listDatabases()) ?? []
        self.driverDatabase = profile.database   // MySQLDriver.connect USE'd this
        self.contexts = []
        self.activeDatabase = nil
        self.scratchContext = DatabaseContext(database: "")

        // Restore the rail: previously-open databases (filtered to ones still present), else the
        // last-viewed db, else the profile's default db.
        let last = PrefsStore.shared.lastView(for: profile.id)
        let saved = PrefsStore.shared.openDatabases(connID: profile.id)
        var railDBs = saved.databases.filter { databases.contains($0) }
        if railDBs.isEmpty {
            if let lastDb = last.database, databases.contains(lastDb) { railDBs = [lastDb] }
            else if let pdb = profile.database, databases.contains(pdb) { railDBs = [pdb] }
        }
        for db in railDBs { contexts.append(DatabaseContext(database: db)) }
        let activeName = saved.active.flatMap { railDBs.contains($0) ? $0 : nil } ?? railDBs.first
        if let activeName {
            try? await openOrActivateDatabase(activeName)
            self.restoredTable = activeContext?.activeTab?.table ?? last.table
        }
        loadHistory()
        loadSavedQueries()
    }

    /// Open a database into the rail (creating its context) or just activate it if already open.
    /// Objects are loaded lazily on first activation; switching back is instant from the snapshot.
    func openOrActivateDatabase(_ name: String) async throws {
        guard driver != nil else { return }
        let ctx = contexts.first { $0.database == name } ?? {
            let c = DatabaseContext(database: name)
            contexts.append(c)
            return c
        }()
        // Instant snapshot swap — the USE round-trip is applied lazily (ensureUSE) only before the
        // next USE-dependent op, so switching to an already-loaded database doesn't block on the network.
        activeDatabase = name
        clearDetail()
        loadSavedQueries()
        if !ctx.objectsLoaded {
            try await ensureUSE(name)
            try await reloadObjects(into: ctx)
            ctx.objectsLoaded = true
            loadRecent()
            restoreTabs(for: ctx)
            restoreQueryTabs(for: ctx)
        }
        if let id = profile?.id {
            PrefsStore.shared.setLastView(connID: id, database: name, table: ctx.activeTab?.table)
            persistOpenDatabases()
        }
    }

    /// Apply `USE db` only when the driver isn't already on it. Cheap no-op on repeat switches.
    private func ensureUSE(_ db: String?) async throws {
        guard let db, !db.isEmpty, db != driverDatabase, let d = driver else { return }
        try await d.selectDatabase(db)
        driverDatabase = db
    }

    /// Remove a database from the rail. If it was active, activate a neighbour (awaiting its USE).
    func closeDatabase(_ name: String) async {
        guard let idx = contexts.firstIndex(where: { $0.database == name }) else { return }
        let wasActive = activeDatabase == name
        contexts.remove(at: idx)
        if wasActive {
            if let next = (contexts.indices.contains(idx) ? contexts[idx] : contexts.last)?.database {
                try? await openOrActivateDatabase(next)
            } else {
                activeDatabase = nil
                clearDetail()
                loadSavedQueries()
            }
        }
        persistOpenDatabases()
    }

    private func persistOpenDatabases() {
        guard let id = profile?.id else { return }
        PrefsStore.shared.setOpenDatabases(connID: id, databases: contexts.map(\.database), active: activeDatabase)
    }

    /// Rebuild a fresh connection after the server dropped an idle one. The old MySQLDriver's
    /// connection is immutable, so we open a new driver (password from Keychain), re-apply the
    /// active database, then atomically swap. Drafts/edits are left untouched.
    func reconnect() async throws {
        guard let profile else { throw SessionError("No active connection to reconnect.") }
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        let pwd = KeychainService.readPassword(for: profile.id) ?? ""
        let newDriver = try await DriverRegistry.open(profile: profile, password: pwd)
        if let db = currentDatabase {
            try await newDriver.selectDatabase(db)
            driverDatabase = db
        } else {
            driverDatabase = profile.database
        }
        let old = driver
        driver = newDriver
        if let old { try? await old.close() }
    }

    /// Run a read-only driver op; if it fails because the connection died, reconnect once and
    /// retry. `op` must read `self.driver` fresh each call so the retry uses the new connection.
    private func withConnectionRetry<T>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch {
            guard let d = driver, d.isConnectionLost(error), !isReconnecting else { throw error }
            try await reconnect()
            return try await op()
        }
    }

    /// Switch to another saved connection without dropping to the welcome screen. The new driver
    /// replaces the old only on success (open throws ⇒ current session stays intact).
    func switchConnection(profile: ConnectionProfile, password: String) async throws {
        guard profile.id != self.profile?.id else { return }
        let old = driver
        try await open(profile: profile, password: password)
        try? await old?.close()
    }

    func close() async {
        if let d = driver { try? await d.close() }
        driver = nil
        profile = nil
        serverInfo = nil
        databases = []
        contexts = []
        activeDatabase = nil
        detailFields = []
        detailEditableRow = nil
        consoleLog = []
        history = []
    }

    func selectDatabase(_ name: String) async throws {
        try await openOrActivateDatabase(name)
    }

    /// Load (or re-load, when `force`) the data page for a table into its tab. The tab is created
    /// in the active context if needed. Cached tabs return instantly unless `force` or a new offset.
    func openTable(_ name: String, offset: Int = 0, force: Bool = false) async {
        // Only load tabs that already exist in the active context (created by openInTab). This
        // prevents a stale (activeDatabase, oldTableName) trigger from fabricating a wrong-db tab.
        guard driver != nil, let ctx = activeContext, let tab = ctx.tab(forTable: name) else { return }
        if ctx.activeTabID == nil { ctx.activeTabID = tab.id }
        if !force && tab.loaded && offset == tab.tableOffset { return }   // snapshot already loaded

        let isFirstLoad = tab.loadToken == 0
        tab.loadToken &+= 1
        let token = tab.loadToken
        // Row-index-keyed drafts are invalidated by a reload (positions change). Clear them so a
        // committed/refreshed table doesn't keep showing stale "uncommitted" marks.
        tab.edits = [:]
        tab.deletedRows = []
        if isFirstLoad { tab.insertDrafts = [] }
        tab.editsVersion &+= 1
        tab.tableOffset = offset
        tab.tableLoading = true
        defer { if token == tab.loadToken { tab.tableLoading = false } }

        let db = tab.database
        let dbEsc = db.replacingOccurrences(of: "`", with: "``")
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        let qualified = "`\(dbEsc)`.`\(escaped)`"
        do {
            try await withConnectionRetry {
                guard let d = self.driver else { return }
                try await self.ensureUSE(db)   // USE-relative metadata (schema/pk) needs the right db
                if isFirstLoad {
                    let schema = (try? await d.tableSchema(for: name)) ?? []
                    guard token == tab.loadToken else { return }   // superseded by a newer load
                    tab.dataSchema = schema
                }
                let sql = "SELECT * FROM \(qualified)\(self.whereClause(tab))\(self.orderClause(tab)) LIMIT \(tab.tablePageSize) OFFSET \(offset)"
                self.logSQL(sql)
                let result = try await d.query(sql)
                guard token == tab.loadToken else { return }
                var cols = (result.rows.first?.columns ?? result.columns).map(\.name)
                if cols.isEmpty { cols = tab.dataSchema.map(\.name) }   // 0-row SELECT carries no column metadata
                tab.tableColumns = cols
                tab.allTableColumns = cols
                tab.tableRows = result.rows
                tab.editsVersion &+= 1   // fresh rows arrived async; re-key the grid so it reloads new content (not the pre-fetch snapshot)
                // PK from the already-fetched schema (COLUMN_KEY='PRI') — no extra query, and never
                // touches information_schema.STATISTICS (CARDINALITY recompute is seconds-slow on wide tables).
                tab.tablePrimaryKeys = Set(tab.dataSchema.filter { $0.key == "PRI" }.map(\.name))
                tab.loaded = true   // grid can show now; row-key + count fill in below without blocking it
                tab.tableRowKey = (try? await d.uniqueKeyColumns(for: name)) ?? []
                guard token == tab.loadToken else { return }
                let countSQL = "SELECT COUNT(*) AS c FROM \(qualified)\(self.whereClause(tab))"
                self.logSQL(countSQL)
                let countResult = try? await d.query(countSQL)
                guard token == tab.loadToken else { return }
                tab.tableTotal = countResult?.rows.first?.string("c").flatMap { Int($0) }
            }
        } catch {
            guard token == tab.loadToken else { return }
            self.error = error.localizedDescription
            tab.tableColumns = []
            tab.tableRows = []
            tab.tableTotal = nil
        }
    }

    var displayColumns: [String] {
        tableColumns.filter { !hiddenColumns.contains($0) }
    }

    private func whereClause(_ tab: TableTabState) -> String {
        let manual = tab.whereText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return " WHERE \(manual)" }
        let active = tab.filters.filter { $0.isValid }
        guard !active.isEmpty else { return "" }
        return " WHERE " + active.map { $0.sql }.joined(separator: " AND ")
    }

    private func orderClause(_ tab: TableTabState) -> String {
        let manual = tab.orderByText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return " ORDER BY \(manual)" }
        guard !tab.orderBy.isEmpty else { return "" }
        let parts = tab.orderBy.map { s in
            "`\(s.column.replacingOccurrences(of: "`", with: "``"))` \(s.ascending ? "ASC" : "DESC")"
        }
        return " ORDER BY " + parts.joined(separator: ", ")
    }

    func applyWhereOrder(where w: String, orderBy o: String) async {
        whereText = w
        orderByText = o
        if !o.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { orderBy = [] }
        await reloadCurrentTable()
    }

    func reloadCurrentTable() async {
        guard let name = currentTable else { return }
        await openTable(name, offset: 0, force: true)
    }

    func toggleSort(_ column: String) async {
        orderByText = ""
        if orderBy.count == 1, orderBy[0].column == column {
            if !orderBy[0].ascending {
                orderBy[0].ascending = true
            } else {
                orderBy = []
            }
        } else {
            orderBy = [SortSpec(column: column, ascending: false)]
        }
        await reloadCurrentTable()
    }

    func applyFilters(_ conditions: [FilterCondition]) async {
        filters = conditions
        await reloadCurrentTable()
    }

    func setHiddenColumns(_ hidden: Set<String>) {
        hiddenColumns = hidden
    }

    func loadStructure(_ name: String) async {
        guard let d = driver, let tab = activeContext?.tab(forTable: name) else { return }
        if tab.structureTable == name && !tab.tableSchema.isEmpty { return }
        tab.structureLoading = true
        tab.structureSection = .fields
        defer { tab.structureLoading = false }
        do {
            try await ensureUSE(tab.database)
            // Write to the captured tab (not the facade) so a rail/tab switch mid-load can't
            // land DB A's structure on DB B's tab.
            tab.tableSchema = try await d.tableSchema(for: name)
            tab.tableIndexes = try await d.tableIndexes(for: name)
            tab.tableTriggers = try await d.tableTriggers(for: name)
            tab.tableDDL = try await d.tableDDL(for: name)
            tab.tableInfo = try await d.tableInfo(for: name)
            tab.structureTable = name
        } catch {
            self.error = error.localizedDescription
            tab.tableSchema = []
            tab.tableIndexes = []
            tab.tableTriggers = []
            tab.tableDDL = nil
            tab.tableInfo = nil
            tab.structureTable = nil
        }
    }

    // MARK: - Right-panel detail (every grid row is clickable → detail)

    func clearDetail() { detailFields = []; detailEditableRow = nil; detailIsQuery = false }

    func showDataRowDetail(_ index: Int) {
        detailIsQuery = false
        let rows = gridRows
        guard rows.indices.contains(index) else { detailFields = []; detailEditableRow = nil; return }
        detailEditableRow = index
        let row = rows[index]
        detailFields = row.columns.map { col in
            DetailField(col.name, row.string(col.name), isKey: tablePrimaryKeys.contains(col.name), tag: col.type)
        }
    }

    /// Live editable check + value for the detail panel (mirrors the grid's draft edits).
    func detailEditableColumn(_ column: String) -> Bool {
        if detailIsQuery { return queryDetailEditableColumn(column) }
        guard let row = detailEditableRow, !isRowDeleted(row) else { return false }
        if case .insert = gridRowKind(at: row) { return !insertSkipColumns.contains(column) }
        let rows = gridRows
        guard rows.indices.contains(row) else { return false }
        if (rows[row].cell(column) ?? .null).isBinaryLike { return false }
        return true
    }


    func showQueryRowDetail(_ index: Int) {
        guard queryRows.indices.contains(index) else { detailFields = []; detailEditableRow = nil; detailIsQuery = false; return }
        let row = queryRows[index]
        let editable = currentQueryPage?.isEditable ?? false
        detailIsQuery = editable
        detailEditableRow = editable ? index : nil
        let keys = Set(currentQueryPage?.editRowKey ?? [])
        detailFields = row.columns.map { col in
            DetailField(col.name, row.string(col.name), isKey: keys.contains(col.name), tag: col.type)
        }
    }

    func showColumnDetail(_ index: Int) {
        detailEditableRow = nil
        guard tableSchema.indices.contains(index) else { detailFields = []; structureSelectedColumn = nil; return }
        let c = tableSchema[index]
        structureSelectedColumn = index
        detailFields = [
            DetailField("column_name", c.name, isKey: c.key == "PRI"),
            DetailField("data_type", c.type),
            DetailField("character_set", c.characterSet),
            DetailField("collation", c.collation),
            DetailField("is_nullable", c.nullable ? "YES" : "NO"),
            DetailField("column_default", c.default),
            DetailField("extra", c.extra),
            DetailField("key", c.key),
            DetailField("foreign_key", c.foreignKey ?? ""),
            DetailField("comment", c.comment),
        ]
    }

    func showIndexDetail(_ index: Int) {
        detailEditableRow = nil
        guard tableIndexes.indices.contains(index) else { detailFields = []; return }
        let i = tableIndexes[index]
        detailFields = [
            DetailField("index_name", i.name),
            DetailField("index_algorithm", i.algorithm),
            DetailField("is_unique", i.unique ? "TRUE" : "FALSE"),
            DetailField("column_name", i.columns.joined(separator: ", ")),
        ]
    }

    func showTriggerDetail(_ index: Int) {
        detailEditableRow = nil
        guard tableTriggers.indices.contains(index) else { detailFields = []; return }
        let t = tableTriggers[index]
        detailFields = [
            DetailField("trigger_name", t.name),
            DetailField("timing", t.timing),
            DetailField("event", t.event),
            DetailField("statement", t.statement),
        ]
    }

    // MARK: - Draft cell edits

    /// Records (or clears, if back to original) one cell edit. `row` is a grid-row index.
    func setEdit(row: Int, column: String, newValue: String?) {
        switch gridRowKind(at: row) {
        case .existing(let r):
            guard let table = currentTable, tableRows.indices.contains(r) else { return }
            let key = "\(r)|\(column)"
            if newValue == tableRows[r].string(column) {
                edits.removeValue(forKey: key)
            } else {
                edits[key] = CellEdit(row: r, column: column, newValue: newValue, table: table)
            }
            // No editsVersion bump: a full grid reload here would interrupt clicking another
            // cell mid-edit. The edited cell refreshes itself in place; discard/commit reload.
        case .insert(let id):
            guard let di = insertDrafts.firstIndex(where: { $0.id == id }) else { return }
            // updateValue (not subscript): subscript-assigning nil removes the key (⇒ DEFAULT);
            // we need .some(nil) to mean an explicit SQL NULL.
            insertDrafts[di].values.updateValue(newValue, forKey: column)
            editsVersion &+= 1   // synthetic draft row has no in-place cell view; reload to repaint
        case nil:
            break
        }
    }

    /// Override for the grid. Outer nil ⇒ not edited; inner nil ⇒ edited to NULL.
    /// Insert-draft rows carry their value in `gridRows` already, so they need no override.
    func editOverride(row: Int, column: String) -> String?? {
        guard case .existing(let r) = gridRowKind(at: row),
              let e = edits["\(r)|\(column)"], e.table == currentTable else { return nil }
        return .some(e.newValue)
    }

    /// Whether a detail field has an uncommitted change (drives the dirty highlight + Revert enablement).
    /// Insert drafts don't go through `editOverride`, so check the draft's own keys.
    func fieldHasEdit(row: Int, column: String) -> Bool {
        if detailIsQuery { return queryFieldHasEdit(row: row, column: column) }
        switch gridRowKind(at: row) {
        case .existing:        return editOverride(row: row, column: column) != nil
        case .insert(let id):  return insertDrafts.first(where: { $0.id == id })?.values.keys.contains(column) ?? false
        case nil:              return false
        }
    }

    /// Current live value of a detail field (pending edit / draft value, else original). "" for NULL/unset.
    func fieldDisplayValue(row: Int, column: String) -> String {
        if detailIsQuery { return queryFieldDisplayValue(row: row, column: column) }
        switch gridRowKind(at: row) {
        case .existing(let r):
            if let e = edits["\(r)|\(column)"], e.table == currentTable { return e.newValue ?? "" }
            return (tableRows.indices.contains(r) ? tableRows[r].string(column) : nil) ?? ""
        case .insert(let id):
            if let d = insertDrafts.first(where: { $0.id == id }), let v = d.values[column] { return v ?? "" }
            return ""
        case nil:
            return ""
        }
    }

    func discardEdits() {
        guard hasEdits || showEditSQL else { return }
        edits = [:]
        insertDrafts = []
        deletedRows = []
        showEditSQL = false
        editsVersion &+= 1
    }

    /// Toggle the delete mark on the given grid rows. Existing rows toggle in `deletedRows`
    /// (all-marked ⇒ unmark, else mark); insert drafts are simply discarded.
    func toggleDelete(_ indices: IndexSet) {
        var existing: [Int] = []
        var drafts: [UUID] = []
        for i in indices {
            switch gridRowKind(at: i) {
            case .existing(let r): existing.append(r)
            case .insert(let id):  drafts.append(id)
            case nil:              break
            }
        }
        drafts.forEach { id in insertDrafts.removeAll { $0.id == id } }
        if !existing.isEmpty {
            if existing.allSatisfy({ deletedRows.contains($0) }) {
                existing.forEach { deletedRows.remove($0) }
            } else {
                existing.forEach { deletedRows.insert($0) }
            }
        }
        editsVersion &+= 1
    }

    func insertRow() {
        guard currentTable != nil else { return }
        insertDrafts.append(InsertDraft())
        requestFocusLastRow()
    }

    /// Grid-row indices carrying an uncommitted change (edited existing, deleted, or insert draft), ascending.
    var editedGridRows: [Int] {
        var set = Set<Int>()
        if let t = currentTable {
            for e in edits.values where e.table == t { set.insert(e.row) }
        }
        set.formUnion(deletedRows)
        let base = tableRows.count
        for i in insertDrafts.indices { set.insert(base + i) }
        return set.sorted()
    }

    /// Cycle focus to the next edited grid row after the currently focused one (wraps).
    func focusNextEditedRow() {
        let rows = editedGridRows
        guard !rows.isEmpty else { return }
        showEditSQL = false
        let current = focusGridRow ?? -1
        focusGridRow = rows.first { $0 > current } ?? rows[0]
        focusToken &+= 1
    }

    /// Focus + scroll to the last grid row (a freshly added draft) and exit SQL preview.
    private func requestFocusLastRow() {
        showEditSQL = false
        focusGridRow = tableRows.count + insertDrafts.count - 1
        focusToken &+= 1
        editsVersion &+= 1
    }

    /// Duplicates a committed row into a new insert draft, skipping computed columns
    /// (auto-increment / generated / BIT ⇒ DB default) and binary-like cells (no text round-trip).
    func duplicateRow(_ index: Int) {
        guard case .existing(let r) = gridRowKind(at: index), tableRows.indices.contains(r) else { return }
        let skip = insertSkipColumns
        let row = tableRows[r]
        var values: [String: String?] = [:]
        for (col, cell) in zip(row.columns, row.cells) where !skip.contains(col.name) && !cell.isBinaryLike {
            values.updateValue(cell.displayText, forKey: col.name)   // keep NULL as .some(nil)
        }
        insertDrafts.append(InsertDraft(values: values))
        requestFocusLastRow()
    }

    /// Reverts one field from the detail panel: existing → drop the cell edit; insert draft → drop
    /// the column (back to DB default). No-op when there's nothing to revert.
    func revertField(column: String) {
        guard let row = detailEditableRow else { return }
        if detailIsQuery { revertQueryField(row: row, column: column); return }
        switch gridRowKind(at: row) {
        case .existing(let r): edits.removeValue(forKey: "\(r)|\(column)")
        case .insert(let id):  if let di = insertDrafts.firstIndex(where: { $0.id == id }) { insertDrafts[di].values.removeValue(forKey: column) }
        case nil:              break
        }
        editsVersion &+= 1
    }


    // Preview & commit order: updates (skipping deleted rows) → deletes → inserts.
    var editSQLText: String { allStatements().joined(separator: "\n\n") }
    private func allStatements() -> [String] { editStatements() + deleteStatements() + insertStatements() }

    func tableHasEdits(_ name: String) -> Bool {
        for ctx in contexts {
            for tab in ctx.tabs where tab.table == name && tab.hasEdits { return true }
        }
        return false
    }

    private func insertStatements() -> [String] { insertDrafts.compactMap { insertSQL(for: $0) } }

    /// One DELETE per marked row, targeted by PK/unique (or all columns) + LIMIT 1.
    private func deleteStatements() -> [String] {
        guard let db = currentDatabase, let table = currentTable else { return [] }
        return deletedRows.sorted().compactMap { idx in
            guard tableRows.indices.contains(idx), let pred = rowPredicate(tableRows[idx]) else { return nil }
            return "DELETE FROM \(Self.ident(db)).\(Self.ident(table))\nWHERE \(pred)\nLIMIT 1;"
        }
    }

    /// One INSERT for a draft. Columns the user never touched are omitted ⇒ DB applies its default.
    private func insertSQL(for draft: InsertDraft) -> String? {
        guard let table = currentTable, let db = currentDatabase else { return nil }
        let present = gridColumnTemplate.filter { draft.values.keys.contains($0.name) }
        guard !present.isEmpty else {
            return "INSERT INTO \(Self.ident(db)).\(Self.ident(table)) () VALUES ();"
        }
        let cols = present.map { Self.ident($0.name) }.joined(separator: ", ")
        let vals = present.map { Self.literal(draft.values[$0.name] ?? nil, numeric: columnIsNumeric($0.name)) }
            .joined(separator: ", ")
        return "INSERT INTO \(Self.ident(db)).\(Self.ident(table))\n    (\(cols))\nVALUES\n    (\(vals));"
    }

    /// One UPDATE per dirty row. Row targeted by PK/unique key (or all columns if neither),
    /// plus the original values of the edited columns, with LIMIT 1 — matches TablePlus.
    private func editStatements() -> [String] {
        guard let table = currentTable, let db = currentDatabase else { return [] }
        let byRow = Dictionary(grouping: edits.values.filter { $0.table == table }) { $0.row }
        return byRow.keys.sorted().compactMap { rowIdx in
            guard tableRows.indices.contains(rowIdx), !deletedRows.contains(rowIdx) else { return nil }   // row being deleted ⇒ no UPDATE
            let row = tableRows[rowIdx]
            let rowEdits = byRow[rowIdx]!.sorted { $0.column < $1.column }
            let sets = rowEdits
                .map { "    \(Self.ident($0.column)) = \(Self.literal($0.newValue, numeric: columnIsNumeric($0.column)))" }
                .joined(separator: ",\n")
            guard let wheres = rowPredicate(row, extraColumns: rowEdits.map(\.column)) else { return nil }
            return "UPDATE \(Self.ident(db)).\(Self.ident(table)) SET\n\(sets)\nWHERE \(wheres)\nLIMIT 1;"
        }
    }

    /// WHERE predicate identifying one row: PK/unique key when present, else all columns,
    /// plus any extra columns, skipping blobs (can't match reliably). nil when nothing usable.
    private func rowPredicate(_ row: DriverRow, extraColumns: [String] = []) -> String? {
        var whereCols = tableRowKey.isEmpty ? tableColumns : tableRowKey
        for c in extraColumns where !whereCols.contains(c) { whereCols.append(c) }
        let wheres = whereCols.compactMap { col -> String? in
            let cell = row.cell(col)
            if case .blob = cell { return nil }
            return Self.whereEq(col, row.string(col), cell, numeric: columnIsNumeric(col))
        }.joined(separator: " AND ")
        return wheres.isEmpty ? nil : wheres
    }

    /// Commits all edits in one transaction. Returns nil on success, else an error message.
    func commitEdits() async -> String? {
        guard !committing else { return nil }
        guard let d = driver else { return "No connection" }
        guard hasEdits else { return nil }
        let stmts = allStatements()
        guard !stmts.isEmpty else { return nil }
        let committedTable = currentTable
        let committedDB = currentDatabase
        committing = true
        defer { committing = false }
        var zeroAffected = 0
        do {
            _ = try await d.query("START TRANSACTION")
            for s in stmts {
                logSQL(s)
                let aff = try await d.execute(s).affectedRows
                NSLog("[commit] affected=%llu :: %@", aff, s.replacingOccurrences(of: "\n", with: " "))
                if aff == 0 { zeroAffected += 1 }
            }
            _ = try await d.query("COMMIT")
        } catch {
            _ = try? await d.query("ROLLBACK")
            return error.localizedDescription
        }
        guard currentTable == committedTable, currentDatabase == committedDB else { return nil }   // switched table/db during commit
        insertDrafts = []   // committed drafts are now real rows; drop them before refetch
        await reloadCurrentTable()
        // A real SQL error already rolled back above; 0-affected is only a soft warning
        // (MySQL counts changed, not matched, rows — an unchanged value also reports 0).
        return zeroAffected > 0 ? String(format: L10n.t("edit.zeroAffected"), zeroAffected) : nil
    }

    private static func ident(_ s: String) -> String {
        "`" + s.replacingOccurrences(of: "`", with: "``") + "`"
    }

    private static func literal(_ value: String?, numeric: Bool) -> String {
        guard let value else { return "NULL" }
        if numeric, let d = Double(value), d.isFinite { return value }   // unquoted only for a finite number
        let esc = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(esc)'"
    }

    /// Equality predicate for WHERE; NULL → `IS NULL`; BIT → `b'..'` literal.
    private static func whereEq(_ col: String, _ value: String?, _ cell: DriverCell?, numeric: Bool) -> String {
        if case .bit(let s)? = cell { return "\(ident(col)) = b'\(s)'" }
        return value == nil ? "\(ident(col)) IS NULL" : "\(ident(col)) = \(literal(value, numeric: numeric))"
    }

    // MARK: - Row context-menu actions

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// Sets one cell to a value (or SQL NULL when nil) from the context menu, repainting the grid.
    func setCellValue(row: Int, column: String, newValue: String?) {
        if detailIsQuery { setQueryEdit(row: row, column: column, newValue: newValue); return }
        setEdit(row: row, column: column, newValue: newValue)
        editsVersion &+= 1
    }

    func copyCell(row: Int, column: String) {
        let rows = gridRows
        guard rows.indices.contains(row) else { return }
        copyToPasteboard((rows[row].cell(column) ?? .null).displayText ?? "")
    }

    func copyRowAsJSON(_ index: Int) {
        let rows = gridRows
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        let body = zip(row.columns, row.cells)
            .map { "  \(Self.jsonString($0.name)): \(Self.jsonValue($1))" }
            .joined(separator: ",\n")
        copyToPasteboard("{\n\(body)\n}")
    }

    func copyRowAsInsert(_ index: Int) {
        // A draft row copies the exact SQL it would commit (unset columns omitted ⇒ DB default).
        if case .insert(let id) = gridRowKind(at: index), let d = insertDrafts.first(where: { $0.id == id }) {
            if let sql = insertSQL(for: d) { copyToPasteboard(sql) }
            return
        }
        let rows = gridRows
        guard let db = currentDatabase, let table = currentTable, rows.indices.contains(index) else { return }
        let row = rows[index]
        let cols = row.columns.map { Self.ident($0.name) }.joined(separator: ", ")
        let vals = row.cells.map { Self.insertLiteral($0) }.joined(separator: ", ")
        copyToPasteboard("INSERT INTO \(Self.ident(db)).\(Self.ident(table)) (\(cols)) VALUES (\(vals));")
    }

    func filterByValue(row: Int, column: String) async {
        guard tableRows.indices.contains(row) else { return }
        let cell = tableRows[row].cell(column) ?? .null
        filters = []   // a typed filter replaces structured filters; don't leave them to "revive"
        whereText = cell.isNull
            ? "\(Self.ident(column)) IS NULL"
            : Self.whereEq(column, cell.displayText, cell, numeric: columnIsNumeric(column))
        await reloadCurrentTable()
    }

    /// SQL literal straight from a typed cell (for INSERT). Blobs → hex; NULL preserved.
    private static func insertLiteral(_ cell: DriverCell) -> String {
        switch cell {
        case .null:           return "NULL"
        case .integer(let i): return String(i)
        case .float(let d):   return d.isFinite ? String(d) : "NULL"
        case .bool(let b):    return b ? "1" : "0"
        case .bit(let s):     return "b'\(s)'"
        case .blob(let d):    return d.isEmpty ? "''" : "X'\(d.map { String(format: "%02x", $0) }.joined())'"
        case .text(let s), .json(let s), .datetime(let s):
            return "'\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''"))'"
        }
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    private static func jsonValue(_ cell: DriverCell) -> String {
        switch cell {
        case .null:           return "null"
        case .integer(let i): return String(i)
        case .float(let d):   return d.isFinite ? String(d) : "null"
        case .bool(let b):    return b ? "true" : "false"
        case .bit(let s):     return jsonString("b'\(s)'")
        case .blob(let d):    return jsonString(d.base64EncodedString())
        case .text(let s), .json(let s), .datetime(let s):
            return jsonString(s)
        }
    }

    func nextPage() async {
        guard let name = currentTable else { return }
        await openTable(name, offset: tableOffset + tablePageSize)
    }

    func prevPage() async {
        guard let name = currentTable, tableOffset >= tablePageSize else { return }
        await openTable(name, offset: tableOffset - tablePageSize)
    }

    func reloadObjects(into ctx: DatabaseContext) async throws {
        guard driver != nil else { return }
        try await withConnectionRetry {
            guard let d = self.driver else { return }
            async let t = d.listTables()
            async let v = d.listViews()
            async let f = d.listFunctions()
            async let p = d.listProcedures()
            // Write to the captured ctx (not the facade) so a rail switch mid-load can't land
            // DB A's object list on DB B.
            ctx.tables     = try await t   // throws on a dead connection → reconnect + retry
            ctx.views      = (try? await v) ?? []
            ctx.functions  = (try? await f) ?? []
            ctx.procedures = (try? await p) ?? []
        }
    }

    /// Runs every statement in the text, one "Query N" result page per statement.
    func runQuery(_ sql: String) async {
        await runStatements(SQLTools.statements(in: sql).map(\.sql))
    }

    func runStatements(_ stmts: [String]) async {
        guard let d = driver, let ctx = activeContext, let tab = ctx.activeQueryTab else { return }
        let list = stmts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return }
        persistQueryTab(tab, ctx: ctx)   // checkpoint this tab's SQL before it runs
        tab.queryCancelled = false
        tab.queryRunning = true
        tab.queryPages = []
        tab.activeQueryPage = 0
        clearDetail()
        defer { tab.queryRunning = false; queryProgress = (0, 0) }
        let db = ctx.database
        try? await ensureUSE(db)   // run the manual SQL against the active database

        var detectCandidates: [(pageIndex: Int, statement: String)] = []
        for (idx, stmt) in list.enumerated() {
            if tab.queryCancelled { break }
            queryProgress = (idx, list.count)
            var sql = stmt
            if let n = queryLimit, SQLTools.wantsLimit(sql) { sql += " LIMIT \(n)" }
            logSQL(sql)

            let pageIndex = tab.queryPages.count
            tab.queryPages.append(QueryPage(sql: sql, running: true))
            tab.activeQueryPage = pageIndex
            let start = Date()

            if SQLTools.producesRows(sql) {
                if let shards = await parallelShards(for: sql, driver: d), !tab.queryCancelled {
                    await streamParallel(tab: tab, pageIndex: pageIndex, shards: shards, start: start, db: db)
                } else if !tab.queryCancelled {
                    await streamInto(tab: tab, pageIndex: pageIndex, driver: d, sql: sql, start: start, db: db)
                }
                detectCandidates.append((pageIndex, stmt))
            } else if !tab.queryCancelled {
                await execInto(tab: tab, pageIndex: pageIndex, driver: d, sql: sql, start: start, db: db)
            }
            queryProgress = (idx + 1, list.count)
        }
        // Editability probe runs AFTER the batch (connection now free) so it never slows time-to-results.
        if !tab.queryCancelled {
            for c in detectCandidates { await detectEditability(tab: tab, pageIndex: c.pageIndex, statement: c.statement) }
        }
        loadHistory()
    }

    /// If `sql` is a single-table SELECT over an integer PK with a large key span, returns N shard
    /// SQLs (one PK range each) to fetch in parallel; else nil (run on one connection).
    private func parallelShards(for sql: String, driver d: any DatabaseDriver) async -> [String]? {
        guard let sel = SQLTools.parseSimpleSelect(sql) else { return nil }
        let schema = (try? await d.tableSchema(for: sel.bareTable)) ?? []
        let pris = schema.filter { $0.key == "PRI" }
        guard pris.count == 1 else { return nil }
        let pk = pris[0]
        let intTypes = ["bigint", "int", "mediumint", "smallint", "tinyint"]
        guard intTypes.contains(where: { pk.type.lowercased().hasPrefix($0) }) else { return nil }

        let pkEsc = "`\(pk.name.replacingOccurrences(of: "`", with: "``"))`"
        let whereSuffix = sel.whereClause.map { " WHERE \($0)" } ?? ""

        // Split by ROW-COUNT percentiles (not value ranges) so skewed / gappy PKs still balance:
        // find the PK at each 1/N row boundary via an indexed ORDER BY … LIMIT 1 OFFSET probe.
        let cntSQL = "SELECT COUNT(*) AS c FROM \(sel.table)\(whereSuffix)"
        guard let cr = try? await d.query(cntSQL), let cs = cr.rows.first?.string("c"),
              let total = Int64(cs), total >= 20_000 else { return nil }

        let n = 4
        var bounds: [Int64] = []
        for i in 1..<n {
            let off = total * Int64(i) / Int64(n)
            let bSQL = "SELECT \(pkEsc) AS b FROM \(sel.table)\(whereSuffix) ORDER BY \(pkEsc) LIMIT 1 OFFSET \(off)"
            guard let br = try? await d.query(bSQL), let bs = br.rows.first?.string("b"),
                  let b = Int64(bs) else { return nil }
            bounds.append(b)
        }
        guard Set(bounds).count == bounds.count else { return nil }   // boundaries collapsed → bail

        func shardCond(_ i: Int) -> String {
            let r: String
            if i == 0 { r = "\(pkEsc) < \(bounds[0])" }
            else if i == n - 1 { r = "\(pkEsc) >= \(bounds[n - 2])" }
            else { r = "\(pkEsc) >= \(bounds[i - 1]) AND \(pkEsc) < \(bounds[i])" }
            return sel.whereClause.map { "(\($0)) AND \(r)" } ?? r
        }
        return (0..<n).map { "SELECT \(sel.selectList) FROM \(sel.table) WHERE \(shardCond($0))" }
    }

    /// Fetches PK-range shards concurrently on dedicated connections (each its own event-loop
    /// thread), saturating the network instead of one connection's CPU. Rows merge into one page.
    private func streamParallel(tab: QueryTabState, pageIndex: Int, shards: [String], start: Date, db: String?) async {
        guard let prof = profile else { return }
        let pwd = KeychainService.readPassword(for: prof.id) ?? ""
        var drivers: [any DatabaseDriver] = []
        for _ in shards {
            guard let drv = try? await DriverRegistry.open(profile: prof, password: pwd) else { break }
            if let db { try? await drv.selectDatabase(db) }
            drivers.append(drv)
        }
        guard drivers.count == shards.count, !tab.queryCancelled else {
            for drv in drivers { try? await drv.close() }
            if !tab.queryCancelled, let d = driver {   // couldn't open all shards → fall back to one connection
                let combined = shards.first.map { _ in shards.joined(separator: " UNION ALL ") } ?? ""
                await streamInto(tab: tab, pageIndex: pageIndex, driver: d, sql: combined, start: start, db: db)
            }
            return
        }
        tab.shardDrivers = drivers
        defer { tab.shardDrivers = [] }

        let conns = drivers
        let sink = RowSink()
        let group = Task.detached {
            nonisolated(unsafe) var firstError: String?
            await withTaskGroup(of: String?.self) { g in
                for (i, shardSQL) in shards.enumerated() {
                    let drv = conns[i]
                    g.addTask {
                        do {
                            _ = try await drv.queryStreaming(shardSQL,
                                onColumns: { sink.setColumns($0.map(\.name)) },
                                onBatch: { sink.append($0) })
                            return nil
                        } catch { return error.localizedDescription }
                    }
                }
                for await e in g where e != nil { if firstError == nil { firstError = e } }
            }
            sink.complete(error: firstError)
        }

        while true {
            let snap = sink.drain()
            guard tab.queryPages.indices.contains(pageIndex) else { break }
            if let cols = snap.columns, tab.queryPages[pageIndex].columns.isEmpty {
                tab.queryPages[pageIndex].columns = cols
            }
            if !snap.rows.isEmpty { tab.queryPages[pageIndex].rows.append(contentsOf: snap.rows) }
            tab.queryPages[pageIndex].elapsed = Date().timeIntervalSince(start)
            if snap.done {
                let dur = Int64(Date().timeIntervalSince(start) * 1000)
                tab.queryPages[pageIndex].running = false
                let n = tab.queryPages[pageIndex].rows.count
                if let err = snap.error, !tab.queryCancelled {
                    tab.queryPages[pageIndex].error = err
                    recordHistory(database: db, sql: shards.first ?? "", durationMs: dur, ok: false, error: err)
                } else {
                    tab.queryPages[pageIndex].message = tab.queryCancelled ? "Cancelled — \(n) rows fetched" : "\(n) rows"
                    recordHistory(database: db, sql: "/* parallel */ \(shards.first ?? "")", durationMs: dur, ok: true, error: nil)
                }
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        _ = await group.value
        for drv in drivers { try? await drv.close() }
    }

    /// Streams a result-set statement into its page, flushing rows to the grid every ~100ms.
    private func streamInto(tab: QueryTabState, pageIndex: Int, driver d: any DatabaseDriver,
                            sql: String, start: Date, db: String?) async {
        let sink = RowSink()
        let task = Task.detached {
            do {
                _ = try await d.queryStreaming(sql,
                    onColumns: { sink.setColumns($0.map(\.name)) },
                    onBatch: { sink.append($0) })
                sink.complete(error: nil)
            } catch {
                sink.complete(error: error.localizedDescription)
            }
        }

        while true {
            let snap = sink.drain()
            guard tab.queryPages.indices.contains(pageIndex) else { break }
            if let cols = snap.columns, tab.queryPages[pageIndex].columns.isEmpty {
                tab.queryPages[pageIndex].columns = cols
            }
            if !snap.rows.isEmpty { tab.queryPages[pageIndex].rows.append(contentsOf: snap.rows) }
            tab.queryPages[pageIndex].elapsed = Date().timeIntervalSince(start)
            if snap.done {
                let dur = Int64(Date().timeIntervalSince(start) * 1000)
                tab.queryPages[pageIndex].running = false
                if let err = snap.error, !tab.queryCancelled {
                    tab.queryPages[pageIndex].error = err
                    recordHistory(database: db, sql: sql, durationMs: dur, ok: false, error: err)
                } else {
                    let n = tab.queryPages[pageIndex].rows.count
                    tab.queryPages[pageIndex].message = tab.queryCancelled
                        ? "Cancelled — \(n) rows fetched"
                        : (tab.queryPages[pageIndex].columns.isEmpty ? "OK" : "\(n) rows")
                    recordHistory(database: db, sql: sql, durationMs: dur, ok: true, error: nil)
                }
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        _ = await task.value
    }

    /// Runs a non-result statement and reports affected rows.
    private func execInto(tab: QueryTabState, pageIndex: Int, driver d: any DatabaseDriver,
                          sql: String, start: Date, db: String?) async {
        do {
            let r = try await d.execute(sql)
            let dur = Int64(Date().timeIntervalSince(start) * 1000)
            guard tab.queryPages.indices.contains(pageIndex) else { return }
            tab.queryPages[pageIndex].running = false
            tab.queryPages[pageIndex].rowsAffected = Int(r.affectedRows)
            tab.queryPages[pageIndex].elapsed = Date().timeIntervalSince(start)
            tab.queryPages[pageIndex].message = "OK: \(r.affectedRows) rows affected"
            recordHistory(database: db, sql: sql, durationMs: dur, ok: true, error: nil)
        } catch {
            let dur = Int64(Date().timeIntervalSince(start) * 1000)
            guard tab.queryPages.indices.contains(pageIndex) else { return }
            tab.queryPages[pageIndex].running = false
            tab.queryPages[pageIndex].elapsed = Date().timeIntervalSince(start)
            tab.queryPages[pageIndex].error = error.localizedDescription
            recordHistory(database: db, sql: sql, durationMs: dur, ok: false, error: error.localizedDescription)
        }
    }

    /// Cancels the running query by issuing `KILL QUERY <id>` on a fresh side connection (the busy
    /// connection can't accept commands while streaming). Best-effort.
    func cancelQuery() {
        guard let tab = activeContext?.activeQueryTab, tab.queryRunning, !tab.queryCancelled else { return }
        tab.queryCancelled = true
        // Parallel fetch: closing the dedicated shard connections aborts their queries.
        if !tab.shardDrivers.isEmpty {
            let drivers = tab.shardDrivers
            Task.detached { for d in drivers { try? await d.close() } }
            return
        }
        // Single connection: it's busy streaming, so KILL QUERY from a side connection.
        guard let id = driver?.serverConnectionID, let profile else { return }
        let pwd = KeychainService.readPassword(for: profile.id) ?? ""
        let prof = profile
        Task.detached {
            guard let side = try? await DriverRegistry.open(profile: prof, password: pwd) else { return }
            _ = try? await side.query("KILL QUERY \(id)")
            try? await side.close()
        }
    }

    // MARK: - Editable query results (single-table only)

    /// After a SELECT finishes, mark its page editable iff it maps to one updatable table whose
    /// unique-key columns are all present in the projection (so a row can be safely targeted).
    private func detectEditability(tab: QueryTabState, pageIndex: Int, statement: String) async {
        guard let d = driver, tab.queryPages.indices.contains(pageIndex),
              tab.queryPages[pageIndex].error == nil, !tab.queryPages[pageIndex].columns.isEmpty,
              let info = SQLTools.editableSelect(statement) else { return }
        let rowKey = (try? await d.uniqueKeyColumns(for: info.bareTable)) ?? []   // single round-trip
        guard tab.queryPages.indices.contains(pageIndex) else { return }
        let resultCols = Set(tab.queryPages[pageIndex].columns)
        guard !rowKey.isEmpty, rowKey.allSatisfy({ resultCols.contains($0) }) else { return }
        tab.queryPages[pageIndex].editTable = info.bareTable
        tab.queryPages[pageIndex].editDatabase = currentDatabase
        tab.queryPages[pageIndex].editRowKey = rowKey
        tab.queryPages[pageIndex].editColumns = resultCols   // single-table SELECT ⇒ projected cols are real
    }

    /// Mutate the page currently shown in the active tab (active page, else last).
    private func mutateQueryPage(_ body: (inout QueryPage) -> Void) {
        guard let tab = activeContext?.activeQueryTab else { return }
        let idx = tab.queryPages.indices.contains(tab.activeQueryPage) ? tab.activeQueryPage : tab.queryPages.count - 1
        guard tab.queryPages.indices.contains(idx) else { return }
        body(&tab.queryPages[idx])
    }

    func setQueryEdit(row: Int, column: String, newValue: String?) {
        mutateQueryPage { p in
            guard p.editTable != nil, p.editColumns.contains(column), p.rows.indices.contains(row) else { return }
            let key = "\(row)|\(column)"
            if newValue == p.rows[row].string(column) { p.queryEdits.removeValue(forKey: key) }
            else { p.queryEdits[key] = newValue }
            p.editsVersion &+= 1
        }
    }

    func queryEditOverride(row: Int, column: String) -> String?? {
        guard let p = currentQueryPage, let e = p.queryEdits["\(row)|\(column)"] else { return nil }
        return .some(e)
    }

    func queryFieldDisplayValue(row: Int, column: String) -> String {
        guard let p = currentQueryPage, p.rows.indices.contains(row) else { return "" }
        if let e = p.queryEdits["\(row)|\(column)"] { return e ?? "" }
        return p.rows[row].string(column) ?? ""
    }

    func queryFieldHasEdit(row: Int, column: String) -> Bool {
        currentQueryPage?.queryEdits["\(row)|\(column)"] != nil
    }

    func queryDetailEditableColumn(_ column: String) -> Bool {
        guard let row = detailEditableRow, let p = currentQueryPage, p.editTable != nil,
              p.editColumns.contains(column), p.rows.indices.contains(row) else { return false }
        return !(p.rows[row].cell(column) ?? .null).isBinaryLike
    }

    func revertQueryField(row: Int, column: String) {
        mutateQueryPage { p in p.queryEdits.removeValue(forKey: "\(row)|\(column)"); p.editsVersion &+= 1 }
    }

    func discardQueryEdits() {
        mutateQueryPage { p in p.queryEdits = [:]; p.editsVersion &+= 1 }
        clearDetail()
    }

    /// Scroll the result grid to the first edited row (clicking the pending-edits bar).
    func focusFirstQueryEdit() {
        guard let p = currentQueryPage, !p.queryEdits.isEmpty else { return }
        let rows = p.queryEdits.keys.compactMap { Int($0.prefix(while: { $0 != "|" })) }
        guard let minRow = rows.min() else { return }
        queryFocusRow = minRow
        queryFocusToken &+= 1
    }

    /// Commits the active page's edits in one transaction (one UPDATE per dirty row, PK-targeted),
    /// then re-runs the page's SQL to show committed data. nil on success, else an error message.
    func commitQueryEdits() async -> String? {
        guard let d = driver, let tab = activeContext?.activeQueryTab else { return nil }
        let idx = tab.queryPages.indices.contains(tab.activeQueryPage) ? tab.activeQueryPage : tab.queryPages.count - 1
        guard tab.queryPages.indices.contains(idx) else { return nil }
        let page = tab.queryPages[idx]
        guard let table = page.editTable, !page.queryEdits.isEmpty else { return nil }
        let stmts = queryUpdateStatements(page: page, table: table, db: page.editDatabase)
        guard !stmts.isEmpty else { return nil }
        tab.queryPages[idx].committingEdits = true
        do {
            _ = try await d.query("START TRANSACTION")
            for s in stmts { logSQL(s); _ = try await d.execute(s) }
            _ = try await d.query("COMMIT")
        } catch {
            _ = try? await d.query("ROLLBACK")
            if tab.queryPages.indices.contains(idx) { tab.queryPages[idx].committingEdits = false }
            return error.localizedDescription
        }
        await rerunQueryPage(tab: tab, idx: idx)
        clearDetail()
        return nil
    }

    private func rerunQueryPage(tab: QueryTabState, idx: Int) async {
        guard let d = driver, tab.queryPages.indices.contains(idx) else { return }
        let sql = tab.queryPages[idx].sql
        let db = activeContext?.database
        tab.queryPages[idx].queryEdits = [:]
        tab.queryPages[idx].committingEdits = false
        tab.queryPages[idx].rows = []
        tab.queryPages[idx].columns = []
        tab.queryPages[idx].running = true
        tab.queryPages[idx].editsVersion &+= 1
        try? await ensureUSE(db)
        await streamInto(tab: tab, pageIndex: idx, driver: d, sql: sql, start: Date(), db: db)
    }

    private func queryColIsNumeric(_ row: DriverRow, _ column: String) -> Bool {
        row.columns.first(where: { $0.name == column })?.isNumeric ?? false
    }

    private func queryUpdateStatements(page: QueryPage, table: String, db: String?) -> [String] {
        func rowIndex(_ key: String) -> Int { Int(key.prefix(while: { $0 != "|" })) ?? -1 }
        func colName(_ key: String) -> String { key.firstIndex(of: "|").map { String(key[key.index(after: $0)...]) } ?? "" }
        let byRow = Dictionary(grouping: page.queryEdits.keys, by: rowIndex)
        let prefix = db.map { "\(Self.ident($0))." } ?? ""
        return byRow.keys.sorted().compactMap { rowIdx -> String? in
            guard page.rows.indices.contains(rowIdx) else { return nil }
            let row = page.rows[rowIdx]
            let cols = byRow[rowIdx]!.map(colName).sorted()
            let sets = cols.map { c -> String in
                let v = page.queryEdits["\(rowIdx)|\(c)"] ?? nil
                return "    \(Self.ident(c)) = \(Self.literal(v, numeric: queryColIsNumeric(row, c)))"
            }.joined(separator: ",\n")
            guard let wheres = queryRowPredicate(page: page, row: row, extraColumns: cols) else { return nil }
            return "UPDATE \(prefix)\(Self.ident(table)) SET\n\(sets)\nWHERE \(wheres)\nLIMIT 1;"
        }
    }

    private func queryRowPredicate(page: QueryPage, row: DriverRow, extraColumns: [String]) -> String? {
        var whereCols = page.editRowKey.isEmpty ? page.columns : page.editRowKey
        for c in extraColumns where !whereCols.contains(c) { whereCols.append(c) }
        let wheres = whereCols.compactMap { col -> String? in
            let cell = row.cell(col)
            if case .blob = cell { return nil }
            return Self.whereEq(col, row.string(col), cell, numeric: queryColIsNumeric(row, col))
        }.joined(separator: " AND ")
        return wheres.isEmpty ? nil : wheres
    }

    private func recordHistory(database: String?, sql: String, durationMs: Int64, ok: Bool, error: String?) {
        guard let pid = profile?.id.uuidString else { return }
        let rec = QueryHistoryRecord(
            id: nil, connection_id: pid, database: database, sql: sql,
            executed_at: Int64(Date().timeIntervalSince1970),
            duration_ms: durationMs, ok: ok, error: error
        )
        try? Persistence.shared.write { db in try rec.insert(db) }
    }

    func loadHistory() {
        guard let pid = profile?.id.uuidString else { history = []; return }
        history = (try? Persistence.shared.read { db in
            try QueryHistoryRecord
                .filter(Column("connection_id") == pid)
                .order(Column("executed_at").desc)
                .limit(100)
                .fetchAll(db)
        }) ?? []
    }

    /// Returns nil on success, or the error message to show inline.
    func executeTrigger(_ sql: String) async -> String? {
        guard let d = driver, let tab = activeTabState else { return "No connection" }
        logSQL(sql)
        do {
            try? await ensureUSE(tab.database)
            _ = try await d.query(sql)
            tab.tableTriggers = (try? await d.tableTriggers(for: tab.table)) ?? []
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns nil on success, or an error message.
    func resetAutoIncrement(_ value: String) async -> String? {
        guard let d = driver, let tab = activeTabState else { return "No table" }
        guard let n = Int64(value.trimmingCharacters(in: .whitespaces)) else { return "Invalid value" }
        let dbEsc = tab.database.replacingOccurrences(of: "`", with: "``")
        let escaped = tab.table.replacingOccurrences(of: "`", with: "``")
        let alterSQL = "ALTER TABLE `\(dbEsc)`.`\(escaped)` AUTO_INCREMENT = \(n)"
        logSQL(alterSQL)
        do {
            try? await ensureUSE(tab.database)
            _ = try await d.query(alterSQL)
            tab.tableInfo = try? await d.tableInfo(for: tab.table)
            tab.tableDDL = try? await d.tableDDL(for: tab.table)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func createDatabase(_ name: String, encoding: String? = nil, collation: String? = nil) async throws {
        guard let d = driver else { return }
        try await d.createDatabase(name: name, encoding: encoding, collation: collation)
        databases = try await d.listDatabases()
    }

}
