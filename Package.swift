// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VEConfigure",
    platforms: [.macOS(.v14)],
    targets: [
        // File formats, settings model, assembler and wizard engine. No UI, fully testable.
        .target(name: "VEKit", linkerSettings: [.linkedLibrary("z")]),
        // Command-line tool: inspect, assemble and write .rvsc files.
        .executableTarget(name: "vecfg", dependencies: ["VEKit"]),
        // The macOS app.
        .executableTarget(name: "VEConfigure", dependencies: ["VEKit"], resources: [.copy("Resources/catalog.json")]),
        .testTarget(name: "VEKitTests", dependencies: ["VEKit"]),
    ]
)
