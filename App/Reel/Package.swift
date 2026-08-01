// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReelAppCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReelAppCore", targets: ["ReelAppCore"])
    ],
    dependencies: [
        .package(path: "../../Packages/CoreModel"),
        .package(path: "../../Packages/LibraryStore"),
        .package(path: "../../Packages/CaptureKit"),
    ],
    targets: [
        .target(
            name: "ReelAppCore",
            dependencies: ["CoreModel", "LibraryStore", "CaptureKit"]
        ),
        .testTarget(
            name: "ReelAppCoreTests",
            dependencies: ["ReelAppCore", "CoreModel", "LibraryStore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
