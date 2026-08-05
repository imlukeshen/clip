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
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
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
