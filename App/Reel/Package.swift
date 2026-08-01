// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReelAppCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReelAppCore", targets: ["ReelAppCore"]),
        .executable(name: "Reel", targets: ["Reel"]),
    ],
    dependencies: [
        .package(path: "../../Packages/CoreModel"),
        .package(path: "../../Packages/LibraryStore"),
        .package(path: "../../Packages/CaptureKit"),
        .package(path: "../../Packages/DesignSystem"),
    ],
    targets: [
        .target(
            name: "ReelAppCore",
            dependencies: ["CoreModel", "LibraryStore", "CaptureKit", "DesignSystem"]
        ),
        .executableTarget(
            name: "Reel",
            dependencies: ["ReelAppCore", "DesignSystem", "LibraryStore", "CaptureKit"]
        ),
        .testTarget(
            name: "ReelAppCoreTests",
            dependencies: ["ReelAppCore", "CoreModel", "LibraryStore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
