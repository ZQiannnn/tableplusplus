import Foundation
import MySQLNIO
import NIOCore
import NIOPosix

final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    static let engine: DatabaseEngine = .mysql
    static let defaultPort: Int = 3306
    static let capabilities: DriverCapabilities = [.ssh, .ssl, .createDatabase]

    // Multiple threads so parallel-fetch shard connections land on different event loops (one
    // connection is pinned to one event loop); `next()` round-robins across them.
    private static let eventLoopGroup: EventLoopGroup =
        MultiThreadedEventLoopGroup(numberOfThreads: max(4, System.coreCount))

    private let connection: MySQLConnection
    private var currentDatabase: String?
    private let connID: Int?

    var serverConnectionID: Int? { connID }

    private init(connection: MySQLConnection, database: String?, connID: Int?) {
        self.connection = connection
        self.currentDatabase = database
        self.connID = connID
    }

    static func connect(
        host: String,
        port: Int,
        user: String,
        password: String,
        database: String?,
        useSSL: Bool
    ) async throws -> MySQLDriver {
        let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
        let conn = try await MySQLConnection.connect(
            to: address,
            username: user,
            database: database ?? "",
            password: password.isEmpty ? nil : password,
            tlsConfiguration: nil,  // TODO: hook SSL via useSSL when we add TLS support
            serverHostname: host,
            logger: .init(label: "tableplusplus.mysql"),
            on: eventLoopGroup.next()
        ).get()
        let idRows = try? await conn.simpleQuery("SELECT CONNECTION_ID() AS id").get()
        let connID = idRows?.first?.column("id")?.int
        return MySQLDriver(connection: conn, database: database, connID: connID)
    }

    func close() async throws {
        try await connection.close().get()
    }

    func ping() async throws {
        _ = try await connection.simpleQuery("SELECT 1").get()
    }

    func isConnectionLost(_ error: Error) -> Bool {
        if connection.isClosed { return true }
        if let e = error as? MySQLError {
            switch e {
            case .closed, .protocolError: return true
            default: break
            }
        }
        if error is ChannelError || error is IOError { return true }
        let s = String(describing: error).lowercased()
        return s.contains("closed") || s.contains("connection reset")
            || s.contains("broken pipe") || s.contains("eof")
            || s.contains("server has gone away") || s.contains("lost connection")
    }

    func serverVersion() async throws -> String {
        let rows = try await connection.simpleQuery("SELECT VERSION()").get()
        let v = rows.first?.column("VERSION()")?.string ?? "unknown"
        return "MySQL \(v)"
    }

    func listDatabases() async throws -> [String] {
        let rows = try await connection.simpleQuery("SHOW DATABASES").get()
        let names: [String] = rows.compactMap { r in
            r.column("Database")?.string ?? r.column("database")?.string
        }
        let filtered = names.filter { !["information_schema", "performance_schema", "mysql", "sys"].contains($0) }
        return filtered.isEmpty ? names : filtered
    }

    func selectDatabase(_ name: String) async throws {
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        _ = try await connection.simpleQuery("USE `\(escaped)`").get()
        currentDatabase = name
    }

    func listTables() async throws -> [String] {
        guard let db = currentDatabase else { return [] }
        let rows = try await connection.simpleQuery("SHOW FULL TABLES WHERE Table_type = 'BASE TABLE'").get()
        let key = "Tables_in_\(db)"
        return rows.compactMap { $0.column(key)?.string }
    }

    func listViews() async throws -> [String] {
        guard let db = currentDatabase else { return [] }
        let rows = try await connection.simpleQuery("SHOW FULL TABLES WHERE Table_type = 'VIEW'").get()
        let key = "Tables_in_\(db)"
        return rows.compactMap { $0.column(key)?.string }
    }

    func listFunctions() async throws -> [String] {
        guard let db = currentDatabase else { return [] }
        let escaped = db.replacingOccurrences(of: "'", with: "''")
        let rows = try await connection.simpleQuery("SHOW FUNCTION STATUS WHERE Db = '\(escaped)'").get()
        return rows.compactMap { $0.column("Name")?.string }
    }

    func listProcedures() async throws -> [String] {
        guard let db = currentDatabase else { return [] }
        let escaped = db.replacingOccurrences(of: "'", with: "''")
        let rows = try await connection.simpleQuery("SHOW PROCEDURE STATUS WHERE Db = '\(escaped)'").get()
        return rows.compactMap { $0.column("Name")?.string }
    }

    func createDatabase(name: String, encoding: String?, collation: String?) async throws {
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        var sql = "CREATE DATABASE `\(escaped)`"
        if let enc = encoding, !enc.isEmpty { sql += " CHARACTER SET \(enc)" }
        if let col = collation, !col.isEmpty { sql += " COLLATE \(col)" }
        _ = try await connection.simpleQuery(sql).get()
    }

    func primaryKeyColumns(for table: String) async throws -> Set<String> {
        // information_schema.STATISTICS, not SHOW KEYS: the latter recomputes index Cardinality
        // (forced fresh by information_schema_stats_expiry=0), which is seconds-slow on wide tables.
        guard let db = currentDatabase else { return [] }
        let dbE = db.replacingOccurrences(of: "'", with: "''")
        let tbE = table.replacingOccurrences(of: "'", with: "''")
        let rows = try await connection.simpleQuery("""
            SELECT COLUMN_NAME
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = '\(dbE)' AND TABLE_NAME = '\(tbE)' AND INDEX_NAME = 'PRIMARY'
        """).get()
        return Set(rows.compactMap { $0.column("COLUMN_NAME")?.string })
    }

    func uniqueKeyColumns(for table: String) async throws -> [String] {
        guard let db = currentDatabase else { return [] }
        let dbE = db.replacingOccurrences(of: "'", with: "''")
        let tbE = table.replacingOccurrences(of: "'", with: "''")
        // KEY_COLUMN_USAGE + TABLE_CONSTRAINTS are pure constraint structure (no CARDINALITY),
        // so this never triggers the slow index-statistics computation that STATISTICS does.
        let rows = try await connection.simpleQuery("""
            SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.TABLE_CONSTRAINTS t
              ON t.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
             AND t.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             AND t.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = '\(dbE)' AND k.TABLE_NAME = '\(tbE)'
              AND t.CONSTRAINT_TYPE IN ('PRIMARY KEY', 'UNIQUE')
            ORDER BY (t.CONSTRAINT_TYPE = 'PRIMARY KEY') DESC, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
        """).get()
        // Columns of the first constraint encountered (PRIMARY preferred, else first unique).
        var chosen: String?
        var cols: [String] = []
        for r in rows {
            guard let cn = r.column("CONSTRAINT_NAME")?.string, let col = r.column("COLUMN_NAME")?.string else { continue }
            if chosen == nil { chosen = cn }
            if cn == chosen { cols.append(col) }
        }
        return cols
    }

    func tableSchema(for table: String) async throws -> [TableColumnInfo] {
        guard let db = currentDatabase else { return [] }
        let dbE = db.replacingOccurrences(of: "'", with: "''")
        let tbE = table.replacingOccurrences(of: "'", with: "''")

        let fkRows = try await connection.simpleQuery("""
            SELECT COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = '\(dbE)' AND TABLE_NAME = '\(tbE)'
                  AND REFERENCED_TABLE_NAME IS NOT NULL
        """).get()
        var fkByColumn: [String: String] = [:]
        for r in fkRows {
            guard let col = r.column("COLUMN_NAME")?.string,
                  let refT = r.column("REFERENCED_TABLE_NAME")?.string else { continue }
            let refC = r.column("REFERENCED_COLUMN_NAME")?.string ?? ""
            fkByColumn[col] = refC.isEmpty ? refT : "\(refT).\(refC)"
        }

        let rows = try await connection.simpleQuery("""
            SELECT COLUMN_NAME, COLUMN_TYPE, CHARACTER_SET_NAME, COLLATION_NAME,
                   IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLUMN_KEY, COLUMN_COMMENT
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = '\(dbE)' AND TABLE_NAME = '\(tbE)'
            ORDER BY ORDINAL_POSITION
        """).get()
        return rows.map { r in
            let name = r.column("COLUMN_NAME")?.string ?? ""
            return TableColumnInfo(
                name: name,
                type: r.column("COLUMN_TYPE")?.string ?? "",
                characterSet: r.column("CHARACTER_SET_NAME")?.string,
                collation: r.column("COLLATION_NAME")?.string,
                nullable: (r.column("IS_NULLABLE")?.string ?? "NO").uppercased() == "YES",
                default: r.column("COLUMN_DEFAULT")?.string,
                extra: r.column("EXTRA")?.string ?? "",
                key: r.column("COLUMN_KEY")?.string ?? "",
                foreignKey: fkByColumn[name],
                comment: r.column("COLUMN_COMMENT")?.string ?? ""
            )
        }
    }

    func tableIndexes(for table: String) async throws -> [TableIndexInfo] {
        guard let db = currentDatabase else { return [] }
        let dbE = db.replacingOccurrences(of: "'", with: "''")
        let tbE = table.replacingOccurrences(of: "'", with: "''")
        let rows = try await connection.simpleQuery("""
            SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, SEQ_IN_INDEX, INDEX_TYPE
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = '\(dbE)' AND TABLE_NAME = '\(tbE)'
            ORDER BY INDEX_NAME, SEQ_IN_INDEX
        """).get()
        var order: [String] = []
        var byName: [String: (algorithm: String, unique: Bool, columns: [String])] = [:]
        for r in rows {
            let name = r.column("INDEX_NAME")?.string ?? ""
            let col = r.column("COLUMN_NAME")?.string ?? ""
            let nonUnique = (r.column("NON_UNIQUE")?.string ?? "1") == "1"
            let algo = r.column("INDEX_TYPE")?.string ?? ""
            if byName[name] == nil {
                order.append(name)
                byName[name] = (algo, !nonUnique, [])
            }
            byName[name]?.columns.append(col)
        }
        return order.map { name in
            let e = byName[name]!
            return TableIndexInfo(name: name, algorithm: e.algorithm, unique: e.unique, columns: e.columns)
        }
    }

    func tableTriggers(for table: String) async throws -> [TableTrigger] {
        guard let db = currentDatabase else { return [] }
        let dbE = db.replacingOccurrences(of: "'", with: "''")
        let tbE = table.replacingOccurrences(of: "'", with: "''")
        let rows = try await connection.simpleQuery("""
            SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT
            FROM information_schema.TRIGGERS
            WHERE TRIGGER_SCHEMA = '\(dbE)' AND EVENT_OBJECT_TABLE = '\(tbE)'
            ORDER BY ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORDER
        """).get()
        return rows.map { r in
            TableTrigger(
                name: r.column("TRIGGER_NAME")?.string ?? "",
                timing: r.column("ACTION_TIMING")?.string ?? "",
                event: r.column("EVENT_MANIPULATION")?.string ?? "",
                statement: r.column("ACTION_STATEMENT")?.string ?? ""
            )
        }
    }

    func tableDDL(for table: String) async throws -> String? {
        let escaped = table.replacingOccurrences(of: "`", with: "``")
        let rows = try await connection.simpleQuery("SHOW CREATE TABLE `\(escaped)`").get()
        guard let r = rows.first else { return nil }
        return r.column("Create Table")?.string ?? r.column("Create View")?.string
    }

    func tableInfo(for table: String) async throws -> TableInfo? {
        guard let db = currentDatabase else { return nil }
        let dbE = db.replacingOccurrences(of: "'", with: "''")
        let tbE = table.replacingOccurrences(of: "'", with: "''")
        let rows = try await connection.simpleQuery("""
            SELECT ENGINE, ROW_FORMAT, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH,
                   AUTO_INCREMENT, TABLE_COLLATION, CREATE_TIME, UPDATE_TIME, TABLE_COMMENT
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '\(dbE)' AND TABLE_NAME = '\(tbE)'
        """).get()
        guard let r = rows.first else { return nil }
        return TableInfo(
            engine: r.column("ENGINE")?.string,
            rowFormat: r.column("ROW_FORMAT")?.string,
            rows: r.column("TABLE_ROWS")?.string,
            dataLength: r.column("DATA_LENGTH")?.string,
            indexLength: r.column("INDEX_LENGTH")?.string,
            autoIncrement: r.column("AUTO_INCREMENT")?.string,
            collation: r.column("TABLE_COLLATION")?.string,
            createTime: r.column("CREATE_TIME")?.string,
            updateTime: r.column("UPDATE_TIME")?.string,
            comment: r.column("TABLE_COMMENT")?.string
        )
    }

    func query(_ sql: String) async throws -> DriverQueryResult {
        let rows = try await connection.simpleQuery(sql).get()
        let columns = (rows.first?.columnDefinitions ?? []).map {
            DriverColumn(name: $0.name, type: Self.label(for: $0.columnType))
        }
        let driverRows: [DriverRow] = rows.map { r in
            // Positional zip — robust to duplicate column names (JOINs).
            let cells = zip(r.columnDefinitions, r.values).map { def, buf -> DriverCell in
                let data = MySQLData(type: def.columnType, format: r.format, buffer: buf,
                                     isUnsigned: def.flags.contains(.COLUMN_UNSIGNED))
                return Self.cell(from: data, isBinary: def.characterSet == .binary)
            }
            return DriverRow(columns: columns, cells: cells)
        }
        return DriverQueryResult(columns: columns, rows: driverRows, rowsAffected: 0)
    }

    func queryStreaming(
        _ sql: String,
        onColumns: @escaping @Sendable ([DriverColumn]) -> Void,
        onBatch: @escaping @Sendable ([DriverRow]) -> Void
    ) async throws -> Int {
        // onRow runs serially on the connection's event loop, so these unsynchronized mutables are
        // touched by one thread only.
        // Decode inline on the connection's event loop. For a parallel fetch each shard runs on its
        // own event-loop thread, so decode parallelises naturally across cores — no extra offload.
        nonisolated(unsafe) var columns: [DriverColumn] = []
        nonisolated(unsafe) var batch: [DriverRow] = []
        nonisolated(unsafe) var total = 0
        try await connection.simpleQuery(sql, onRow: { row in
            if columns.isEmpty {
                columns = row.columnDefinitions.map { DriverColumn(name: $0.name, type: Self.label(for: $0.columnType)) }
                onColumns(columns)
            }
            let cols = columns
            let cells = zip(row.columnDefinitions, row.values).map { def, buf -> DriverCell in
                let data = MySQLData(type: def.columnType, format: row.format, buffer: buf,
                                     isUnsigned: def.flags.contains(.COLUMN_UNSIGNED))
                return Self.cell(from: data, isBinary: def.characterSet == .binary)
            }
            batch.append(DriverRow(columns: cols, cells: cells))
            total += 1
            if batch.count >= 1000 { onBatch(batch); batch = [] }
        }).get()
        if !batch.isEmpty { onBatch(batch) }
        return total
    }

    /// Binary/prepared protocol — exposes the OK-packet metadata that `simpleQuery` discards.
    /// Single-statement only; transaction control / SHOW / USE stay on `query` (text protocol).
    func execute(_ sql: String) async throws -> DriverExecResult {
        // Prepared protocol takes a single statement — drop any trailing ';'.
        var stmt = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if stmt.hasSuffix(";") { stmt.removeLast() }
        nonisolated(unsafe) var affected: UInt64 = 0
        nonisolated(unsafe) var lastID: UInt64?
        try await connection.query(stmt, [], onRow: { _ in }, onMetadata: { meta in
            affected = meta.affectedRows
            lastID = meta.lastInsertID
        }).get()
        return DriverExecResult(affectedRows: affected, lastInsertID: lastID)
    }

    /// Converts a text-protocol MySQLData into a typed DriverCell.
    /// `isBinary` (charset 63) forces blob even when the bytes happen to be valid UTF-8.
    private static func cell(from data: MySQLData, isBinary: Bool) -> DriverCell {
        guard data.buffer != nil else { return .null }
        switch data.type {
        case .tiny, .short, .long, .int24, .longlong, .year:
            if let i = data.int { return .integer(Int64(i)) }   // else falls through (unsigned overflow → text)
        case .float, .double, .decimal, .newdecimal:
            if let s = data.string { return .text(s) }          // preserve exact server text
        case .date, .datetime, .timestamp, .time:
            if let s = data.string { return .datetime(s) }
        case .json:
            if let s = data.string { return .json(s) }
        case .bit:
            if let buf = data.buffer {
                var value: UInt64 = 0
                for b in buf.readableBytesView { value = (value << 8) | UInt64(b) }
                return .bit(value == 0 ? "0" : String(value, radix: 2))
            }
        case .blob, .tinyBlob, .mediumBlob, .longBlob:
            if isBinary, let buf = data.buffer { return .blob(Data(buf.readableBytesView)) }
        default:
            break
        }
        if !isBinary, let s = data.string { return .text(s) }
        if let buf = data.buffer { return .blob(Data(buf.readableBytesView)) }
        return .null
    }

    /// Maps MySQL wire-protocol type → user-facing label matching TablePlus convention.
    private static func label(for type: MySQLProtocol.DataType) -> String {
        switch type {
        case .tiny:        return "tiny"
        case .short:       return "short"
        case .long:        return "long"
        case .longlong:    return "longlong"
        case .int24:       return "int24"
        case .float:       return "float"
        case .double:      return "double"
        case .decimal:     return "decimal"
        case .newdecimal:  return "decimal"
        case .timestamp:   return "timestamp"
        case .date:        return "date"
        case .time:        return "time"
        case .datetime:    return "datetime"
        case .year:        return "year"
        case .string:      return "string"
        case .varString:   return "var_string"
        case .varchar:     return "varchar"
        case .blob:        return "blob"
        case .tinyBlob:    return "tiny_blob"
        case .mediumBlob:  return "medium_blob"
        case .longBlob:    return "long_blob"
        case .json:        return "json"
        case .bit:         return "bit"
        case .enum:        return "enum"
        case .set:         return "set"
        case .null:        return "null"
        default:           return String(describing: type)
        }
    }
}
