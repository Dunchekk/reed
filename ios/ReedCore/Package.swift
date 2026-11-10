// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ReedCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReedDomain", targets: ["ReedDomain"]),
        .library(name: "ReedApplication", targets: ["ReedApplication"]),
        .library(name: "ReedPersistence", targets: ["ReedPersistence"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")],
    targets: [
        .target(name: "ReedDomain"),
        .target(name: "ReedApplication", dependencies: ["ReedDomain"]),
        .target(name: "ReedPersistence", dependencies: ["ReedDomain", "ReedApplication", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ReedDomainTests", dependencies: ["ReedDomain", "ReedApplication"]),
        .testTarget(name: "ReedPersistenceTests", dependencies: ["ReedDomain", "ReedApplication", "ReedPersistence"]),
    ]
)
