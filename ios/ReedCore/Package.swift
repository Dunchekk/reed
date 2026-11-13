// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ReedCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReedDomain", targets: ["ReedDomain"]),
        .library(name: "ReedApplication", targets: ["ReedApplication"]),
        .library(name: "ReedPersistence", targets: ["ReedPersistence"]),
        .library(name: "ReedNetworking", targets: ["ReedNetworking"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")],
    targets: [
        .target(name: "ReedDomain", exclude: ["README.md"]),
        .target(name: "ReedApplication", dependencies: ["ReedDomain"], exclude: ["README.md"]),
        .target(name: "ReedPersistence", dependencies: ["ReedDomain", "ReedApplication", .product(name: "GRDB", package: "GRDB.swift")], exclude: ["README.md"]),
        .target(name: "ReedNetworking", dependencies: ["ReedDomain", "ReedApplication"], exclude: ["README.md"]),
        .testTarget(name: "ReedNetworkingTests", dependencies: ["ReedNetworking", "ReedApplication", "ReedDomain"], exclude: ["README.md"]),
        .testTarget(name: "ReedApplicationTests", dependencies: ["ReedDomain", "ReedApplication"], exclude: ["README.md"]),
        .testTarget(name: "ReedDomainTests", dependencies: ["ReedDomain", "ReedApplication"], exclude: ["README.md"]),
        .testTarget(name: "ReedPersistenceTests", dependencies: ["ReedDomain", "ReedApplication", "ReedPersistence", .product(name: "GRDB", package: "GRDB.swift")], exclude: ["README.md"]),
    ]
)
