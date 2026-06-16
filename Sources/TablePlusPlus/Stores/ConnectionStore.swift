import Foundation
import Observation
import GRDB

@MainActor
@Observable
final class ConnectionStore {
    var profiles: [ConnectionProfile] = []

    init() {
        load()
    }

    func load() {
        let records = (try? Persistence.shared.read { db in
            try ConnectionRecord
                .order(Column("created_at").asc)
                .fetchAll(db)
        }) ?? []
        profiles = records.compactMap { $0.toProfile() }
    }

    func upsert(_ profile: ConnectionProfile) {
        var rec = ConnectionRecord(profile: profile)
        try? Persistence.shared.write { db in
            // Preserve original created_at on update so order doesn't shuffle.
            if let existing = try ConnectionRecord.fetchOne(db, key: rec.id) {
                rec.created_at = existing.created_at
            }
            try rec.save(db)
        }
        load()
    }

    func remove(_ id: UUID) {
        let idStr = id.uuidString
        try? Persistence.shared.write { db in
            _ = try ConnectionRecord.deleteOne(db, key: idStr)
            try db.execute(sql: "DELETE FROM recent_objects WHERE connection_id = ?", arguments: [idStr])
        }
        load()
    }
}
