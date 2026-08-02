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
        .package(path: "../../Packages/ConvertKit"),
        .package(path: "../../Packages/MediaEngine"),
        .package(path: "../../Packages/PDFEngine"),
        .package(path: "../../Packages/AIKit"),
        .package(path: "../../Packages/DesignSystem"),
    ],
    targets: [
        .target(
            name: "ReelAppCore",
            dependencies: [
                "CoreModel",
                "LibraryStore",
                "CaptureKit",
                "ConvertKit",
                "MediaEngine",
                "PDFEngine",
                "AIKit",
                "DesignSystem",
            ]
        ),
        .executableTarget(
            name: "Reel",
            dependencies: [
                "ReelAppCore",
                "DesignSystem",
                "LibraryStore",
                "CaptureKit",
                "ConvertKit",
                "MediaEngine",
                "PDFEngine",
                "AIKit",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .copy("Resources/ACKNOWLEDGEMENTS.md"),
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "ReelAppCoreTests",
            dependencies: [
                "ReelAppCore", "CoreModel", "LibraryStore", "ConvertKit", "MediaEngine", "PDFEngine",
                "AIKit",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
