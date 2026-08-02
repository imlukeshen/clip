// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PDFEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PDFEngine", targets: ["PDFEngine"])
    ],
    dependencies: [
        .package(path: "../CoreModel"),
        .package(path: "../../Vendor/pdfium"),
    ],
    targets: [
        .target(
            name: "PDFEngine",
            dependencies: [
                "CoreModel",
                .product(name: "PDFium", package: "pdfium"),
            ]
        ),
        .testTarget(name: "PDFEngineTests", dependencies: ["PDFEngine", "CoreModel"]),
    ],
    swiftLanguageModes: [.v6]
)
