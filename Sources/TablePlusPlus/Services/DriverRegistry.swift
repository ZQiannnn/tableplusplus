import Foundation

enum DatabaseEngine: String, Codable, CaseIterable, Hashable {
    case mysql
    case mariadb
    case postgres
    case sqlite

    var label: String {
        switch self {
        case .mysql:    "MySQL"
        case .mariadb:  "MariaDB"
        case .postgres: "PostgreSQL"
        case .sqlite:   "SQLite"
        }
    }
    var shortBadge: String {
        switch self {
        case .mysql:    "Ms"
        case .mariadb:  "Mr"
        case .postgres: "Pg"
        case .sqlite:   "Sl"
        }
    }
}

enum DriverRegistryError: Error, LocalizedError {
    case engineNotImplemented(DatabaseEngine)
    var errorDescription: String? {
        switch self {
        case .engineNotImplemented(let e):
            return "\(e.label) driver is not implemented yet"
        }
    }
}

/// Resolves a profile's engine → driver factory.
/// Add a new engine by registering it in `factories` below.
enum DriverRegistry {
    typealias Factory = @Sendable (
        _ host: String,
        _ port: Int,
        _ user: String,
        _ password: String,
        _ database: String?,
        _ useSSL: Bool
    ) async throws -> any DatabaseDriver

    /// Map of engine → factory. Keep alphabetical, one line per engine.
    /// To add a new driver: implement `DatabaseDriver`, add a line here. NOTHING ELSE.
    private static let factories: [DatabaseEngine: Factory] = [
        .mysql:   { try await MySQLDriver.connect(host: $0, port: $1, user: $2, password: $3, database: $4, useSSL: $5) },
        .mariadb: { try await MySQLDriver.connect(host: $0, port: $1, user: $2, password: $3, database: $4, useSSL: $5) },
    ]

    /// Engines that are wired up (and showable as "enabled" in the type picker).
    static var implementedEngines: [DatabaseEngine] {
        DatabaseEngine.allCases.filter { factories[$0] != nil }
    }

    static func defaultPort(for engine: DatabaseEngine) -> Int {
        switch engine {
        case .mysql, .mariadb: 3306
        case .postgres:        5432
        case .sqlite:          0
        }
    }

    static func capabilities(for engine: DatabaseEngine) -> DriverCapabilities {
        switch engine {
        case .mysql, .mariadb: [.ssh, .ssl, .createDatabase]
        case .postgres:        [.ssh, .ssl, .createDatabase, .schemaNamespace]
        case .sqlite:          [.createDatabase]
        }
    }

    static func open(
        profile: ConnectionProfile,
        password: String
    ) async throws -> any DatabaseDriver {
        guard let factory = factories[profile.engine] else {
            throw DriverRegistryError.engineNotImplemented(profile.engine)
        }
        return try await factory(
            profile.host,
            profile.port,
            profile.user,
            password,
            profile.database,
            profile.useSSL
        )
    }
}
