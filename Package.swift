// swift-tools-version: 5.10
import PackageDescription

// The Swift reference engine: the TypeScript port in web/ is checked against it byte for byte.
let package = Package(
    name: "Shunt",
    platforms: [.macOS(.v14)],
    targets: [
        // File formats, settings model, assembler and wizard engine.
        .target(name: "VEKit", linkerSettings: [.linkedLibrary("z")]),
        // Command-line tool: inspect, assemble and write .rvsc files.
        .executableTarget(name: "vecfg", dependencies: ["VEKit"]),
        // Reference data for the TypeScript tests (needs private device files, see web/README.md).
        .executableTarget(name: "vegolden", dependencies: ["VEKit"]),
        .testTarget(name: "VEKitTests", dependencies: ["VEKit"]),
    ]
)
