import Foundation
import NIOCore

/// One result column: name + engine-specific type label ("longlong", "varchar", ...).
struct DriverColumn: Sendable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let type: String

    init(name: String, type: String = "") {
        self.name = name
        self.type = type
    }

    /// Numeric by declared column type — DECIMAL/FLOAT/DOUBLE are kept as text cells
    /// to preserve server formatting, so cell-level isNumeric misses them for alignment.
    var isNumeric: Bool {
        ["tiny", "short", "long", "longlong", "int24", "float", "double", "decimal", "year"].contains(type)
    }
}

/// A typed cell value. Preserves type so the grid can align/format and editing can round-trip.
enum DriverCell: Sendable, Equatable {
    case null
    case text(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
    case datetime(String)     // server-normalized string; avoids timezone round-trip loss
    case blob(Data)
    case json(String)
    case bit(String)          // binary digits without the b'' wrapper, e.g. "101"

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// True for cells that can't round-trip through the plain text editor (need a literal form).
    var isBinaryLike: Bool {
        switch self {
        case .blob, .bit: return true
        default: return false
        }
    }

    var isNumeric: Bool {
        switch self {
        case .integer, .float: return true
        default: return false
        }
    }

    /// Display string for grid / detail / SQL preview. nil ⇔ SQL NULL.
    var displayText: String? {
        switch self {
        case .null:            return nil
        case .text(let s):     return s
        case .json(let s):     return s
        case .datetime(let s): return s
        case .integer(let i):  return String(i)
        case .float(let d):    return String(d)
        case .bool(let b):     return b ? "1" : "0"
        case .bit(let s):      return "b'\(s)'"
        case .blob(let d):     return "(BLOB \(ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .binary)))"
        }
    }
}

/// One row: cells aligned positionally with the result's columns.
struct DriverRow: Sendable {
    let columns: [DriverColumn]
    let cells: [DriverCell]

    func cell(_ column: String) -> DriverCell? {
        guard let i = columns.firstIndex(where: { $0.name == column }) else { return nil }
        return cells[i]
    }

    /// Display string by column name. nil ⇔ NULL or unknown column.
    func string(_ column: String) -> String? {
        cell(column)?.displayText ?? nil
    }
}

extension DriverRow {
    /// Synthetic text-only row (Structure grids). Missing key or nil value ⇒ NULL.
    init(columns names: [String], values: [String: String?]) {
        self.columns = names.map { DriverColumn(name: $0) }
        self.cells = names.map { name in
            if let v = values[name], let s = v { return .text(s) }
            return .null
        }
    }
}

struct DriverQueryResult {
    let columns: [DriverColumn]
    let rows: [DriverRow]
    let rowsAffected: UInt64
}

/// Result of a single non-result-set statement (INSERT/UPDATE/DELETE/DDL).
struct DriverExecResult: Sendable {
    let affectedRows: UInt64
    let lastInsertID: UInt64?
}

/// One column's metadata for the Structure view.
struct TableColumnInfo: Identifiable {
    var id: String { name }
    let name: String
    let type: String          // full COLUMN_TYPE, e.g. "varchar(255)"
    let characterSet: String?
    let collation: String?
    let nullable: Bool
    let `default`: String?
    let extra: String         // "auto_increment", "on update CURRENT_TIMESTAMP", ...
    let key: String           // PRI / UNI / MUL / ""
    let foreignKey: String?   // "ref_table.ref_column" or nil
    let comment: String
}

/// One index's metadata for the Structure view.
struct TableIndexInfo: Identifiable {
    var id: String { name }
    let name: String
    let algorithm: String     // BTREE / HASH / FULLTEXT
    let unique: Bool
    let columns: [String]
}

/// One trigger's metadata for the Structure view.
struct TableTrigger: Identifiable {
    var id: String { name }
    let name: String
    let timing: String        // BEFORE / AFTER
    let event: String         // INSERT / UPDATE / DELETE
    let statement: String
}

/// Table-level metadata for the Structure → Info view.
struct TableInfo: Equatable {
    var engine: String?
    var rowFormat: String?
    var rows: String?
    var dataLength: String?
    var indexLength: String?
    var autoIncrement: String?
    var collation: String?
    var createTime: String?
    var updateTime: String?
    var comment: String?
}

/// Capability flags so the UI can hide unsupported features per engine.
struct DriverCapabilities: OptionSet {
    let rawValue: Int
    static let ssh             = DriverCapabilities(rawValue: 1 << 0)
    static let ssl             = DriverCapabilities(rawValue: 1 << 1)
    static let createDatabase  = DriverCapabilities(rawValue: 1 << 2)
    static let schemaNamespace = DriverCapabilities(rawValue: 1 << 3) // PG-style schemas
}

/// SPI: a database driver. All work is async, on no specific actor.
/// Implementations must be thread-safe (use NIO eventloop or actor).
protocol DatabaseDriver: AnyObject, Sendable {
    /// The engine this driver implements. Used by the registry.
    static var engine: DatabaseEngine { get }
    static var defaultPort: Int { get }
    static var capabilities: DriverCapabilities { get }

    /// Open a connection. Returned driver is in the "connected" state.
    static func connect(
        host: String,
        port: Int,
        user: String,
        password: String,
        database: String?,
        useSSL: Bool
    ) async throws -> Self

    func close() async throws

    /// Quick liveness probe (e.g. `SELECT 1`).
    func ping() async throws

    /// True when `error` (thrown by a previous call) means the underlying connection is dead
    /// (server idle-timeout, reset socket, closed channel) and the caller should reconnect+retry,
    /// as opposed to a genuine SQL error. Default `false`.
    func isConnectionLost(_ error: Error) -> Bool

    /// Server version label e.g. "MySQL 8.4.7" or "PostgreSQL 16.1".
    func serverVersion() async throws -> String

    /// All databases (MySQL) / catalogs (PG) the connected user can see.
    func listDatabases() async throws -> [String]

    /// Switch the session to `name`. For PG this may reconnect; drivers decide.
    func selectDatabase(_ name: String) async throws

    /// Tables in the currently-selected database.
    func listTables() async throws -> [String]

    /// Views in the currently-selected database.
    func listViews() async throws -> [String]

    /// Stored functions in the currently-selected database.
    func listFunctions() async throws -> [String]

    /// Stored procedures in the currently-selected database.
    func listProcedures() async throws -> [String]

    /// Create a database with optional encoding/collation.
    /// Throw if driver lacks `.createDatabase` capability.
    func createDatabase(name: String, encoding: String?, collation: String?) async throws

    /// Raw query escape hatch. Drivers convert engine-specific row types into DriverRow.
    func query(_ sql: String) async throws -> DriverQueryResult

    /// MySQL connection/thread id of this session, for cancelling a running query via `KILL QUERY`
    /// from a separate connection. nil when the engine/driver can't provide one.
    var serverConnectionID: Int? { get }

    /// Streaming query: `onColumns` fires once when the column set is known, `onBatch` for each
    /// chunk of rows as they arrive off the wire (so the UI can fill progressively). Returns total
    /// rows. Both closures run off the main actor. Cancel out-of-band via `KILL QUERY`.
    func queryStreaming(
        _ sql: String,
        onColumns: @escaping @Sendable ([DriverColumn]) -> Void,
        onBatch: @escaping @Sendable ([DriverRow]) -> Void
    ) async throws -> Int

    /// Execute a single non-result-set statement (INSERT/UPDATE/DELETE/DDL), returning affected rows.
    /// Must be one statement — drivers may use a protocol that rejects multi-statement input.
    func execute(_ sql: String) async throws -> DriverExecResult

    /// Primary-key column names for a table in the current database.
    func primaryKeyColumns(for table: String) async throws -> Set<String>

    /// Ordered columns of the best row identifier — PRIMARY key if any, else a UNIQUE index.
    /// Empty when the table has neither (caller falls back to all columns).
    func uniqueKeyColumns(for table: String) async throws -> [String]

    /// Column metadata for the Structure view.
    func tableSchema(for table: String) async throws -> [TableColumnInfo]

    /// Index metadata for the Structure view.
    func tableIndexes(for table: String) async throws -> [TableIndexInfo]

    /// Trigger metadata for the Structure → Triggers view.
    func tableTriggers(for table: String) async throws -> [TableTrigger]

    /// CREATE TABLE statement for the Structure → Info view.
    func tableDDL(for table: String) async throws -> String?

    /// Table-level metadata for the Structure → Info view.
    func tableInfo(for table: String) async throws -> TableInfo?
}

/// Defaults: drivers that don't have a concept return empty.
/// Override in concrete drivers when the engine supports it.
extension DatabaseDriver {
    func isConnectionLost(_ error: Error) -> Bool { false }
    var serverConnectionID: Int? { nil }
    func queryStreaming(
        _ sql: String,
        onColumns: @escaping @Sendable ([DriverColumn]) -> Void,
        onBatch: @escaping @Sendable ([DriverRow]) -> Void
    ) async throws -> Int {
        let r = try await query(sql)
        if !r.columns.isEmpty { onColumns(r.columns) }
        if !r.rows.isEmpty { onBatch(r.rows) }
        return r.rows.count
    }
    func listViews() async throws -> [String] { [] }
    func listFunctions() async throws -> [String] { [] }
    func listProcedures() async throws -> [String] { [] }
    func primaryKeyColumns(for table: String) async throws -> Set<String> { [] }
    func uniqueKeyColumns(for table: String) async throws -> [String] { [] }
    func tableSchema(for table: String) async throws -> [TableColumnInfo] { [] }
    func tableIndexes(for table: String) async throws -> [TableIndexInfo] { [] }
    func tableTriggers(for table: String) async throws -> [TableTrigger] { [] }
    func tableDDL(for table: String) async throws -> String? { nil }
    func tableInfo(for table: String) async throws -> TableInfo? { nil }
}
