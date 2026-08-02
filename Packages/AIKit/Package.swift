// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AIKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AIKit", targets: ["AIKit"])],
    dependencies: [.package(path: "../CoreModel")],
    targets: [
        .target(
            name: "AIKit",
            dependencies: ["CoreModel"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
            ]
        ),
        .testTarget(name: "AIKitTests", dependencies: ["AIKit", "CoreModel"]),
    ],
    swiftLanguageModes: [.v6]
)
