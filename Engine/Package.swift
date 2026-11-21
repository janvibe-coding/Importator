// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ImportatorEngine", targets: ["ImportatorEngine"]),
        .executable(name: "importator", targets: ["importator"]),
    ],
    targets: [
        .target(name: "ImportatorEngine", resources: [.copy("Resources/ExifTool.bundle")]),
        .executableTarget(name: "importator", dependencies: ["ImportatorEngine"]),
        .testTarget(name: "ImportatorEngineTests", dependencies: ["ImportatorEngine"]),
    ]
)
