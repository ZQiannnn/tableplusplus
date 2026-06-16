import Foundation

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var tag: String
    var color: StatusColor?
    var engine: DatabaseEngine
    var host: String
    var port: Int
    var user: String
    var database: String?
    var useSSL: Bool
    var ssh: SSHConfig?
    var favorite: Bool

    static func new(engine: DatabaseEngine = .mysql) -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: "New Connection",
            tag: "local",
            color: nil,
            engine: engine,
            host: "127.0.0.1",
            port: DriverRegistry.defaultPort(for: engine),
            user: "",
            database: nil,
            useSSL: false,
            ssh: nil,
            favorite: false
        )
    }

    // Backward compat: older JSON files don't have `engine` → default to mysql.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id       = try c.decode(UUID.self, forKey: .id)
        self.name     = try c.decode(String.self, forKey: .name)
        self.tag      = try c.decodeIfPresent(String.self, forKey: .tag) ?? "local"
        self.color    = try c.decodeIfPresent(StatusColor.self, forKey: .color)
        self.engine   = try c.decodeIfPresent(DatabaseEngine.self, forKey: .engine) ?? .mysql
        self.host     = try c.decode(String.self, forKey: .host)
        self.port     = try c.decode(Int.self, forKey: .port)
        self.user     = try c.decode(String.self, forKey: .user)
        self.database = try c.decodeIfPresent(String.self, forKey: .database)
        self.useSSL   = try c.decodeIfPresent(Bool.self, forKey: .useSSL) ?? false
        self.ssh      = try c.decodeIfPresent(SSHConfig.self, forKey: .ssh)
        self.favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
    }

    init(id: UUID, name: String, tag: String, color: StatusColor?, engine: DatabaseEngine,
         host: String, port: Int, user: String, database: String?, useSSL: Bool,
         ssh: SSHConfig?, favorite: Bool) {
        self.id = id; self.name = name; self.tag = tag; self.color = color; self.engine = engine
        self.host = host; self.port = port; self.user = user; self.database = database
        self.useSSL = useSSL; self.ssh = ssh; self.favorite = favorite
    }
}

enum StatusColor: String, Codable, CaseIterable {
    case gray, blue, yellow, green, red
}

struct SSHConfig: Codable, Hashable {
    var host: String
    var port: Int
    var user: String
    var auth: SSHAuth
}

enum SSHAuth: Codable, Hashable {
    case password
    case privateKey(path: String)
}
