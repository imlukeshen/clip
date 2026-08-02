// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FFmpegVendor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReelFFmpeg", targets: ["ReelFFmpeg"])
    ],
    targets: [
        .binaryTarget(name: "ReelFFmpeg", path: "ReelFFmpeg.xcframework")
    ]
)
