// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TextEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TextEngine", targets: ["TextEngine"])
    ],
    dependencies: [
        .package(path: "../CoreModel")
    ],
    targets: [
        .target(
            name: "TextEngine",
            dependencies: ["CoreModel"]
        ),
        .testTarget(name: "TextEngineTests", dependencies: ["TextEngine", "CoreModel"]),
    ],
    swiftLanguageModes: [.v6]
)
