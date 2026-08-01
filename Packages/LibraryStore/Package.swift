// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LibraryStore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LibraryStore", targets: ["LibraryStore"])
    ],
    dependencies: [
        .package(path: "../CoreModel"),
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.0.0")),
    ],
    targets: [
        .target(
            name: "LibraryStore",
            dependencies: [
                "CoreModel",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "LibraryStoreTests", dependencies: ["LibraryStore", "CoreModel"]),
    ],
    swiftLanguageModes: [.v6]
)
