// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "potluckdb",
    platforms: [.macOS(.v11), .iOS(.v13)],
    products: [
        .library(name: "potluckdb", targets: ["potluckdb"]),
        .library(name: "potluckdbObjC", targets: ["potluckdbObjC"]),
    ],
    targets: [
        .binaryTarget(
            name: "PotluckDBRuntime",
            url: "https://downloads.potluckdb.dev/releases/0.1.0/swift/PotluckDBRuntime-0.1.0.xcframework.zip",
            checksum: "ce04d02d5627fd1478ddd40ba14b1da0db04220189a660a207c3df2ddfec3f22"
        ),
        .target(
            name: "potluckdb",
            dependencies: ["PotluckDBRuntime"],
            linkerSettings: [.linkedLibrary("c"), .linkedLibrary("m"), .linkedLibrary("iconv"), .linkedLibrary("System")]
        ),
        .target(
            name: "potluckdbObjC",
            dependencies: ["PotluckDBRuntime"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("c"), .linkedLibrary("m"), .linkedLibrary("iconv"), .linkedLibrary("System")]
        )
    ]
)
