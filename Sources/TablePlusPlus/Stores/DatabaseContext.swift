import Foundation
import Observation

/// All state for one open table tab: its loaded data page, draft edits, filters/sort,
/// structure view, and focus requests. Row-index-keyed `edits`/`deletedRows` MUST live here
/// (never globally) so drafts can't bleed across tabs or databases.
@MainActor
@Observable
final class TableTabState: Identifiable {
    let id = UUID()
    let database: String
    let table: String

    init(database: String, table: String) {
        self.database = database
        self.table = table
    }

    var viewerMode: SessionStore.ViewerMode = .data
    var structureSelectedColumn: Int?

    // Data page
    var tableColumns: [String] = []
    var tablePrimaryKeys: Set<String> = []
    var tableRowKey: [String] = []
    var tableRows: [DriverRow] = []
    var tableOffset: Int = 0
    var tablePageSize: Int = 300
    var tableTotal: Int?
    var tableLoading: Bool = false
    var loaded: Bool = false   // a successful data load happened → rail/tab switch can show the snapshot
    var allTableColumns: [String] = []
    var dataSchema: [TableColumnInfo] = []
    var loadToken: Int = 0

    // Filters / sort / column visibility
    var hiddenColumns: Set<String> = []
    var filters: [FilterCondition] = []
    var orderBy: [SortSpec] = []
    var whereText: String = ""
    var orderByText: String = ""

    // Draft mutations
    var edits: [String: CellEdit] = [:]
    var insertDrafts: [InsertDraft] = []
    var deletedRows: Set<Int> = []
    var editsVersion: Int = 0
    var showEditSQL: Bool = false
    var committing: Bool = false

    // Grid focus request
    var focusToken: Int = 0
    var focusGridRow: Int?

    // Structure view
    var structureSection: SessionStore.StructureSection = .fields
    var tableSchema: [TableColumnInfo] = []
    var tableIndexes: [TableIndexInfo] = []
    var tableTriggers: [TableTrigger] = []
    var tableDDL: String?
    var tableInfo: TableInfo?
    var structureLoading: Bool = false
    var structureTable: String?

    // MARK: Derived display state (per tab — each tab's grid computes its own)

    var hasEdits: Bool { !edits.isEmpty || !insertDrafts.isEmpty || !deletedRows.isEmpty }
    var draftCount: Int { edits.count + insertDrafts.count + deletedRows.count }

    var displayColumns: [String] { tableColumns.filter { !hiddenColumns.contains($0) } }

    var gridColumnTemplate: [DriverColumn] {
        tableRows.first?.columns ?? tableColumns.map { DriverColumn(name: $0) }
    }

    /// Committed rows followed by uncommitted insert drafts.
    var gridRows: [DriverRow] {
        guard !insertDrafts.isEmpty else { return tableRows }
        let cols = gridColumnTemplate
        let drafts = insertDrafts.map { draft -> DriverRow in
            let cells = cols.map { c -> DriverCell in
                guard let v = draft.values[c.name] else { return .text("") }
                return v.map { DriverCell.text($0) } ?? .null
            }
            return DriverRow(columns: cols, cells: cells)
        }
        return tableRows + drafts
    }

    func gridRowKind(at index: Int) -> GridRowKind? {
        if index < tableRows.count { return .existing(index) }
        let di = index - tableRows.count
        guard insertDrafts.indices.contains(di) else { return nil }
        return .insert(insertDrafts[di].id)
    }

    func isRowDeleted(_ index: Int) -> Bool {
        if case .existing(let r) = gridRowKind(at: index) { return deletedRows.contains(r) }
        return false
    }

    var insertSkipColumns: Set<String> {
        Set(dataSchema.filter {
            let e = $0.extra.lowercased()
            return e.contains("auto_increment") || e.contains("generated")
                || e.contains("virtual") || e.contains("stored")
                || $0.type.lowercased().hasPrefix("bit")
        }.map(\.name))
    }

    /// Override for the grid. Outer nil ⇒ not edited; inner nil ⇒ edited to NULL.
    func editOverride(row: Int, column: String) -> String?? {
        guard !edits.isEmpty else { return nil }   // fast path: no string-key alloc per cell when clean
        guard case .existing(let r) = gridRowKind(at: row),
              let e = edits["\(r)|\(column)"], e.table == table else { return nil }
        return .some(e.newValue)
    }
}

/// One SQL query tab inside a database's console: its own editor text, result pages, and run state.
/// State MUST live here (never globally) so a run started in one tab can't bleed into another when
/// the user switches tabs mid-fetch. `queryCancelled`/`shardDrivers` are per-tab for the same reason.
@MainActor
@Observable
final class QueryTabState: Identifiable {
    let id = UUID()
    var persistID: Int64?
    var name: String
    var editorSQL: String
    var queryPages: [QueryPage] = []
    var activeQueryPage: Int = 0
    var queryRunning: Bool = false
    var queryCancelled = false
    /// Temporary connections used by a parallel fetch — closing them cancels their shard.
    var shardDrivers: [any DatabaseDriver] = []

    init(name: String, persistID: Int64? = nil, sql: String = "") {
        self.name = name
        self.persistID = persistID
        self.editorSQL = sql
    }
}

/// One open database (a TablePlus-style workspace in the left rail): its object lists, its open
/// table tabs, and its own SQL query tabs. Switching the rail just swaps which context is active;
/// each retains its snapshot so the switch is instant. Query tabs are bound to (connection, database).
@MainActor
@Observable
final class DatabaseContext: Identifiable {
    let id = UUID()
    let database: String

    init(database: String) {
        self.database = database
        let t = QueryTabState(name: "Query 1")
        queryTabs = [t]
        activeQueryTabID = t.id
    }

    var tables: [String] = []
    var views: [String] = []
    var functions: [String] = []
    var procedures: [String] = []
    var recent: [String] = []
    var objectsLoaded = false

    var tabs: [TableTabState] = []
    var activeTabID: UUID?

    // SQL query tabs (per database)
    var queryTabs: [QueryTabState] = []
    var activeQueryTabID: UUID?

    var activeQueryTab: QueryTabState? {
        if let id = activeQueryTabID, let t = queryTabs.first(where: { $0.id == id }) { return t }
        return queryTabs.first
    }

    var activeTab: TableTabState? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    func tab(forTable table: String) -> TableTabState? {
        tabs.first { $0.table == table }
    }
}
