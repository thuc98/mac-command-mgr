// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CommandManager",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "CommandManager", targets: ["CommandManager"]),
        .executable(name: "cmgr", targets: ["cmgr"]),
        .library(name: "CommandManagerCore", targets: ["CommandManagerCore"]),
    ],
    targets: [
        .target(name: "CommandManagerCore"),
        .executableTarget(
            name: "CommandManager",
            dependencies: ["CommandManagerCore"]
        ),
        .executableTarget(
            name: "cmgr",
            dependencies: ["CommandManagerCore"]
        ),
        .testTarget(
            name: "CommandManagerCoreTests",
            dependencies: ["CommandManagerCore"]
        ),
    ]
)
