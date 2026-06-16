import Foundation
import Observation
import GRDB

/// All user preferences live here, backed by SQLite (`ui_prefs` table).
/// Use Bindings into the typed accessors below; do NOT use UserDefaults / @AppStorage.
///
/// Future: backup/restore = copy `tpp.sqlite`. See `Persistence.databaseURL`.
@MainActor
@Observable
final class PrefsStore {
    static let shared = PrefsStore()

    // Typed cache. Add new pref by adding a property + key constant + load/save below.
    var language: String       = "auto"
    var showRecently: Bool     = true
    var showFunctions: Bool    = true
    var showViews: Bool        = true
    var welcomeWidth: Double   = 720
    var welcomeHeight: Double  = 540

    private enum Key {
        static let language        = "language"
        static let showRecently    = "showRecently"
        static let showFunctions   = "showFunctions"
        static let showViews       = "showViews"
        static let welcomeWidth    = "welcomeWidth"
        static let welcomeHeight   = "welcomeHeight"
    }

    private init() {
        load()
        migrateFromUserDefaultsIfNeeded()
    }

    // MARK: - load / save

    private func load() {
        let dict = readAll()
        language       = dict[Key.language] ?? "auto"
        showRecently   = bool(dict[Key.showRecently],   default: true)
        showFunctions  = bool(dict[Key.showFunctions],  default: true)
        showViews      = bool(dict[Key.showViews],      default: true)
        welcomeWidth   = Double(dict[Key.welcomeWidth]  ?? "")  ?? 720
        welcomeHeight  = Double(dict[Key.welcomeHeight] ?? "")  ?? 540
    }

    /// Generic setter — also updates cached property.
    func set(_ key: String, _ value: String) {
        try? Persistence.shared.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO ui_prefs (key, value) VALUES (?, ?)", arguments: [key, value])
        }
        load()
    }

    func setLanguage(_ v: String)      { set(Key.language, v) }
    func setShowRecently(_ v: Bool)    { set(Key.showRecently,   v ? "true" : "false") }
    func setShowFunctions(_ v: Bool)   { set(Key.showFunctions,  v ? "true" : "false") }
    func setShowViews(_ v: Bool)       { set(Key.showViews,      v ? "true" : "false") }
    func setWelcomeSize(width: Double, height: Double) {
        set(Key.welcomeWidth, String(width))
        set(Key.welcomeHeight, String(height))
    }

    // Per-connection last-view state
    func setLastView(connID: UUID, database: String?, table: String?) {
        set("lastView.\(connID.uuidString)", "\(database ?? "")|\(table ?? "")")
    }

    // Per-connection+database open tabs (first line = active tab, rest = tab names)
    func setOpenTabs(connID: UUID, database: String?, tabs: [String], active: String?) {
        let key = "tabs.\(connID.uuidString).\(database ?? "")"
        set(key, ([active ?? ""] + tabs).joined(separator: "\n"))
    }

    func openTabs(connID: UUID, database: String?) -> (tabs: [String], active: String?) {
        let raw = readAll()["tabs.\(connID.uuidString).\(database ?? "")"] ?? ""
        guard !raw.isEmpty else { return ([], nil) }
        var parts = raw.components(separatedBy: "\n")
        let active = parts.first.flatMap { $0.isEmpty ? nil : $0 }
        if !parts.isEmpty { parts.removeFirst() }
        return (parts, active)
    }

    // Per-connection open databases for the left rail (first line = active, rest = rail order)
    func setOpenDatabases(connID: UUID, databases: [String], active: String?) {
        set("openDatabases.\(connID.uuidString)", ([active ?? ""] + databases).joined(separator: "\n"))
    }

    func openDatabases(connID: UUID) -> (databases: [String], active: String?) {
        let raw = readAll()["openDatabases.\(connID.uuidString)"] ?? ""
        guard !raw.isEmpty else { return ([], nil) }
        var parts = raw.components(separatedBy: "\n")
        let active = parts.first.flatMap { $0.isEmpty ? nil : $0 }
        if !parts.isEmpty { parts.removeFirst() }
        return (parts, active)
    }

    func lastView(for connID: UUID) -> (database: String?, table: String?) {
        let raw = readAll()["lastView.\(connID.uuidString)"] ?? ""
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let db = parts.count > 0 && !parts[0].isEmpty ? parts[0] : nil
        let tb = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return (db, tb)
    }

    // MARK: - private helpers

    private func readAll() -> [String: String] {
        (try? Persistence.shared.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM ui_prefs")
            var out: [String: String] = [:]
            for r in rows {
                if let k: String = r["key"], let v: String = r["value"] {
                    out[k] = v
                }
            }
            return out
        }) ?? [:]
    }

    private func bool(_ raw: String?, default def: Bool) -> Bool {
        guard let raw else { return def }
        return raw == "true" || raw == "1"
    }

    private func migrateFromUserDefaultsIfNeeded() {
        let d = UserDefaults.standard
        let legacy: [(String, String)] = [
            ("TablePlusPlus.language", Key.language),
            ("TablePlusPlus.showRecentlySection", Key.showRecently),
            ("TablePlusPlus.showFunctionsSection", Key.showFunctions),
            ("TablePlusPlus.showViewsSection", Key.showViews),
        ]
        let dict = readAll()
        var migrated = false
        for (old, new) in legacy where d.object(forKey: old) != nil {
            if dict[new] == nil {
                let val: String
                if let b = d.object(forKey: old) as? Bool { val = b ? "true" : "false" }
                else { val = d.string(forKey: old) ?? "" }
                set(new, val)
                migrated = true
            }
            d.removeObject(forKey: old)
        }
        if migrated { load() }
    }
}
