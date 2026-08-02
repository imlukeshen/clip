// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConvertKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConvertKit", targets: ["ConvertKit"])
    ],
    dependencies: [
        .package(path: "../CoreModel"),
        .package(path: "../LibraryStore"),
        .package(path: "../../Vendor/ffmpeg"),
    ],
    targets: [
        .target(
            name: "ConvertKit",
            dependencies: [
                "CoreModel",
                "LibraryStore",
                .product(name: "ReelFFmpeg", package: "ffmpeg"),
            ]
        ),
        .testTarget(
            name: "ConvertKitTests",
            dependencies: ["ConvertKit", "CoreModel", "LibraryStore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
