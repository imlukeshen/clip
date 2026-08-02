// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "pdfium",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PDFium", targets: ["PDFium"])
    ],
    targets: [
        .binaryTarget(name: "PDFium", path: "PDFium.xcframework")
    ]
)
