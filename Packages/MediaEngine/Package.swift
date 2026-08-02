// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MediaEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MediaEngine", targets: ["MediaEngine"])
    ],
    dependencies: [
        .package(path: "../CoreModel")
    ],
    targets: [
        .target(name: "MediaEngine", dependencies: ["CoreModel"]),
        .testTarget(name: "MediaEngineTests", dependencies: ["MediaEngine", "CoreModel"]),
    ],
    swiftLanguageModes: [.v6]
)
