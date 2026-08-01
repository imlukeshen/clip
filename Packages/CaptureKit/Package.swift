// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CaptureKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"])
    ],
    dependencies: [
        .package(path: "../CoreModel"),
        .package(path: "../LibraryStore"),
    ],
    targets: [
        .target(name: "CaptureKit", dependencies: ["CoreModel", "LibraryStore"]),
        .testTarget(
            name: "CaptureKitTests",
            dependencies: ["CaptureKit", "LibraryStore"],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
