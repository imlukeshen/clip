// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SearchEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SearchEngine", targets: ["SearchEngine"])
    ],
    dependencies: [
        .package(path: "../CoreModel"),
        .package(path: "../LibraryStore"),
    ],
    targets: [
        .target(name: "SearchEngine", dependencies: ["CoreModel", "LibraryStore"]),
        .testTarget(
            name: "SearchEngineTests",
            dependencies: ["SearchEngine", "CoreModel", "LibraryStore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
