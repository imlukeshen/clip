// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CoreModel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CoreModel", targets: ["CoreModel"])
    ],
    targets: [
        .target(name: "CoreModel"),
        .testTarget(
            name: "CoreModelTests",
            dependencies: ["CoreModel"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
