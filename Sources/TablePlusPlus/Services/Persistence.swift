import Foundation
import GRDB

/// All app persistence lives in one SQLite file managed here.
/// - Connections list (replaces old connections.json)
/// - Recently opened objects per (connection, database)
/// - Query history
/// - UI prefs (window size, language, etc.)
///
/// Migration policy: every schema bump = new `registerMigration` entry. Never edit an old one.
enum Persistence {
    static let shared: DatabaseQueue = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePlusPlus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tpp.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
            try migrator.migrate(queue)
        } catch {
            fatalError("Persistence init failed: \(error)")
        }
        return queue
    }()

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial") { db in
            try db.create(table: "connections") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("tag", .text).notNull().defaults(to: "local")
                t.column("color", .text)
                t.column("engine", .text).notNull().defaults(to: "mysql")
                t.column("host", .text).notNull()
                t.column("port", .integer).notNull()
                t.column("user", .text).notNull()
                t.column("database", .text)
                t.column("use_ssl", .boolean).notNull().defaults(to: false)
                t.column("ssh_json", .text)
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("created_at", .integer).notNull().defaults(sql: "(strftime('%s','now'))")
            }

            try db.create(table: "recent_objects") { t in
                t.column("connection_id", .text).notNull()
                t.column("database", .text).notNull()
                t.column("object_name", .text).notNull()
                t.column("opened_at", .integer).notNull()
                t.primaryKey(["connection_id", "database", "object_name"])
            }

            try db.create(table: "query_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connection_id", .text).notNull()
                t.column("database", .text)
                t.column("sql", .text).notNull()
                t.column("executed_at", .integer).notNull()
                t.column("duration_ms", .integer)
                t.column("ok", .boolean).notNull()
                t.column("error", .text)
            }

            try db.create(table: "ui_prefs") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }

        m.registerMigration("v2_query_tabs") { db in
            try db.create(table: "query_tabs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connection_id", .text).notNull()
                t.column("database", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sql", .text).notNull().defaults(to: "")
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("updated_at", .integer).notNull().defaults(sql: "(strftime('%s','now'))")
            }
        }

        m.registerMigration("v3_saved_queries") { db in
            try db.create(table: "saved_queries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("connection_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sql", .text).notNull()
                t.column("updated_at", .integer).notNull().defaults(sql: "(strftime('%s','now'))")
            }
        }

        m.registerMigration("v4_saved_queries_database") { db in
            try db.alter(table: "saved_queries") { t in
                t.add(column: "database", .text).notNull().defaults(to: "")
            }
        }

        return m
    }

    // MARK: - Saved queries (bound to connection; named SQL snippets shown in the Queries sidebar)

    static func loadSavedQueries(connID: String, database: String) -> [SavedQueryRecord] {
        (try? shared.read { db in
            try SavedQueryRecord
                .filter(Column("connection_id") == connID && Column("database") == database)
                .order(Column("updated_at").desc)
                .fetchAll(db)
        }) ?? []
    }

    static func insertSavedQuery(connID: String, database: String, name: String, sql: String) -> Int64? {
        try? shared.write { db in
            var rec = SavedQueryRecord(id: nil, connection_id: connID, database: database,
                                       name: name, sql: sql,
                                       updated_at: Int64(Date().timeIntervalSince1970))
            try rec.insert(db)
            return rec.id
        }
    }

    static func deleteSavedQuery(id: Int64) {
        _ = try? shared.write { db in try SavedQueryRecord.deleteOne(db, key: id) }
    }

    // MARK: - Query tabs (bound to connection + database; SQL text only, no result sets)

    static func loadQueryTabs(connID: String, database: String) -> [QueryTabRecord] {
        (try? shared.read { db in
            try QueryTabRecord.fetchAll(db, sql: """
                SELECT * FROM query_tabs WHERE connection_id = ? AND database = ?
                ORDER BY position, id
            """, arguments: [connID, database])
        }) ?? []
    }

    static func upsertQueryTab(id: Int64?, connID: String, database: String,
                               name: String, sql: String, position: Int) -> Int64? {
        try? shared.write { db in
            var rec = QueryTabRecord(id: id, connection_id: connID, database: database,
                                     name: name, sql: sql, position: position,
                                     updated_at: Int64(Date().timeIntervalSince1970))
            try rec.save(db)
            return rec.id
        }
    }

    static func deleteQueryTab(id: Int64) {
        _ = try? shared.write { db in try QueryTabRecord.deleteOne(db, key: id) }
    }

    // MARK: - One-shot legacy import (JSON / UserDefaults → SQLite)

    static func importLegacyIfNeeded() {
        importLegacyConnectionsJSON()
        importLegacyRecent()
    }

    private static func importLegacyConnectionsJSON() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePlusPlus", isDirectory: true)
        let url = dir.appendingPathComponent("connections.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        guard let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return }
        try? shared.write { db in
            for p in profiles {
                if try ConnectionRecord.fetchOne(db, key: p.id.uuidString) == nil {
                    let rec = ConnectionRecord(profile: p)
                    try rec.insert(db)
                }
            }
        }
        // Rename so we don't re-import next launch
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("imported"))
    }

    private static func importLegacyRecent() {
        // UserDefaults keys: "TablePlusPlus.recent.<connID>.<dbName>"
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let prefix = "TablePlusPlus.recent."
        for (k, v) in defaults where k.hasPrefix(prefix) {
            let suffix = String(k.dropFirst(prefix.count))
            guard let dot = suffix.firstIndex(of: ".") else { continue }
            let connID = String(suffix[..<dot])
            let db = String(suffix[suffix.index(after: dot)...])
            guard let list = v as? [String] else { continue }
            let now = Date().timeIntervalSince1970
            try? shared.write { dbConn in
                for (i, name) in list.enumerated() {
                    let ts = Int(now) - i
                    try dbConn.execute(sql: """
                        INSERT OR REPLACE INTO recent_objects (connection_id, database, object_name, opened_at)
                        VALUES (?, ?, ?, ?)
                    """, arguments: [connID, db, name, ts])
                }
            }
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}

// MARK: - Records

struct ConnectionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "connections"

    var id: String          // UUID string
    var name: String
    var tag: String
    var color: String?
    var engine: String      // raw DatabaseEngine.rawValue
    var host: String
    var port: Int
    var user: String
    var database: String?
    var use_ssl: Bool
    var ssh_json: String?
    var favorite: Bool
    var created_at: Int64

    init(profile p: ConnectionProfile) {
        self.id = p.id.uuidString
        self.name = p.name
        self.tag = p.tag
        self.color = p.color?.rawValue
        self.engine = p.engine.rawValue
        self.host = p.host
        self.port = p.port
        self.user = p.user
        self.database = p.database
        self.use_ssl = p.useSSL
        self.ssh_json = p.ssh.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? nil
        self.favorite = p.favorite
        self.created_at = Int64(Date().timeIntervalSince1970)
    }

    func toProfile() -> ConnectionProfile? {
        guard let uuid = UUID(uuidString: id),
              let engine = DatabaseEngine(rawValue: engine) else { return nil }
        let color = color.flatMap { StatusColor(rawValue: $0) }
        var ssh: SSHConfig?
        if let json = ssh_json, let data = json.data(using: .utf8) {
            ssh = try? JSONDecoder().decode(SSHConfig.self, from: data)
        }
        return ConnectionProfile(
            id: uuid, name: name, tag: tag, color: color, engine: engine,
            host: host, port: port, user: user, database: database,
            useSSL: use_ssl, ssh: ssh, favorite: favorite
        )
    }
}

struct RecentObjectRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "recent_objects"
    var connection_id: String
    var database: String
    var object_name: String
    var opened_at: Int64
}

struct QueryTabRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "query_tabs"
    var id: Int64?
    var connection_id: String
    var database: String
    var name: String
    var sql: String
    var position: Int
    var updated_at: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct SavedQueryRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "saved_queries"
    var id: Int64?
    var connection_id: String
    var database: String
    var name: String
    var sql: String
    var updated_at: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct QueryHistoryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "query_history"
    var id: Int64?
    var connection_id: String
    var database: String?
    var sql: String
    var executed_at: Int64
    var duration_ms: Int64?
    var ok: Bool
    var error: String?
}
