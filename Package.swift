// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TablePlusPlus",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "TablePlusPlus",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
