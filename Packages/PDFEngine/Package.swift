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
                "PDFiumSupport",
                .product(name: "PDFium", package: "pdfium"),
            ]
        ),
        .target(
            name: "PDFiumSupport",
            dependencies: [.product(name: "PDFium", package: "pdfium")],
            publicHeadersPath: "include"
        ),
        .testTarget(name: "PDFEngineTests", dependencies: ["PDFEngine", "CoreModel"]),
    ],
    swiftLanguageModes: [.v6]
)
