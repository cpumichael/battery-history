// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryHistory",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BatteryHistoryCore", targets: ["BatteryHistoryCore"]),
        .executable(name: "BatteryHistory", targets: ["BatteryHistory"]),
        .executable(name: "HistoryStorageProbe", targets: ["HistoryStorageProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/duckdb/duckdb-swift.git", exact: "1.1.3")
    ],
    targets: [
        .target(name: "BatteryHistoryCore", dependencies: [.product(name: "DuckDB", package: "duckdb-swift")],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "BatteryHistory", dependencies: ["BatteryHistoryCore"]),
        .executableTarget(name: "HistoryStorageProbe", dependencies: ["BatteryHistoryCore"]),
        .testTarget(name: "BatteryHistoryCoreTests", dependencies: ["BatteryHistoryCore"])
    ]
)
