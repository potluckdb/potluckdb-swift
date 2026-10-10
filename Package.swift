// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "potluckdb",
    platforms: [.macOS(.v11), .iOS(.v15)],
    products: [
        .library(name: "potluckdb", targets: ["potluckdb"]),
        .library(name: "potluckdbObjC", targets: ["potluckdbObjC"]),
    ],
    targets: [
        .binaryTarget(
            name: "PotluckDBRuntime",
            url: "https://downloads.potluckdb.com/releases/0.1.0/swift/PotluckDBRuntime-0.1.0.xcframework.zip",
            checksum: "40529a80816b01cac17ed7f1d5d3c922a192906038072812ffac544a7f63be46"
        ),
        .binaryTarget(
            name: "PotluckDBStorage",
            url: "https://downloads.potluckdb.com/releases/0.1.0/swift/PotluckDBStorage-0.1.0.xcframework.zip",
            checksum: "eab62aa926c741e06c8a5cba46d41870f5cd800272e1d2e2982c955e258182d4"
        ),
        .binaryTarget(
            name: "PotluckDBStorageMacOS",
            url: "https://downloads.potluckdb.com/releases/0.1.0/swift/PotluckDBStorage-macos-0.1.0.xcframework.zip",
            checksum: "7d3e41bec977cd0158a245edcae1baee62f4bed100cf5338ec22612f54a50081"
        ),
        .target(
            name: "potluckdb",
            dependencies: [
                "PotluckDBRuntime",
                .target(name: "PotluckDBStorage", condition: .when(platforms: [.iOS])),
                .target(name: "PotluckDBStorageMacOS", condition: .when(platforms: [.macOS])),
            ],
            linkerSettings: [.linkedLibrary("c"), .linkedLibrary("m"), .linkedLibrary("iconv"), .linkedLibrary("System")]
        ),
        .target(
            name: "potluckdbObjC",
            dependencies: [
                "PotluckDBRuntime",
                .target(name: "PotluckDBStorage", condition: .when(platforms: [.iOS])),
                .target(name: "PotluckDBStorageMacOS", condition: .when(platforms: [.macOS])),
            ],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("c"), .linkedLibrary("m"), .linkedLibrary("iconv"), .linkedLibrary("System")]
        )
    ]
)
