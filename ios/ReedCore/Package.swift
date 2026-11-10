// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ReedCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReedDomain", targets: ["ReedDomain"]),
        .library(name: "ReedApplication", targets: ["ReedApplication"]),
    ],
    targets: [
        .target(name: "ReedDomain"),
        .target(name: "ReedApplication", dependencies: ["ReedDomain"]),
        .testTarget(name: "ReedDomainTests", dependencies: ["ReedDomain", "ReedApplication"]),
    ]
)
