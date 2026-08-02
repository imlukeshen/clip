import CoreGraphics
import CoreModel
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MediaEngine

@Test func redactedExportDestroysSourcePixelsAndStripsSensitiveMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-redaction-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceURL = directory.appendingPathComponent("source.jpg")
    let outputURL = directory.appendingPathComponent("redacted.png")
    let source = try checkerboard(width: 16, height: 16)
    try writeSourceWithSensitiveMetadata(source, to: sourceURL)

    let redaction = RedactionLayer(
        id: LayerID(rawValue: "security-redaction"),
        regions: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)],
        style: .pixelate(size: 4)
    )
    let document = try ImageDocument(
        sourceAssetID: AssetID(rawValue: "sensitive-source"),
        canvas: ImageCanvas(width: 16, height: 16),
        layers: [.redaction(redaction)]
    )
    let renderer = ImageDocumentRenderer(useSoftwareRenderer: true)
    try renderer.export(document, sourceURL: sourceURL, to: outputURL, format: .png)

    guard let exportedSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
        let exported = CGImageSourceCreateImageAtIndex(exportedSource, 0, nil)
    else { throw ImageRenderError.unreadableSource }
    guard let decodedSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
        let decodedSourceImage = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil)
    else { throw ImageRenderError.unreadableSource }
    let sourcePixels = try rgbaPixels(decodedSourceImage)
    let exportedPixels = try rgbaPixels(exported)
    for blockY in stride(from: 4, to: 12, by: 4) {
        for blockX in stride(from: 4, to: 12, by: 4) {
            try assertMeanFilledBlock(
                source: sourcePixels,
                exported: exportedPixels,
                width: 16,
                x: blockX,
                y: blockY,
                size: 4
            )
        }
    }

    let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(exportedSource, 0, nil) as? [CFString: Any]
    )
    #expect(properties[kCGImagePropertyExifDictionary] == nil)
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    #expect(CGImageSourceGetCount(exportedSource) == 1)
    let exportedData = try Data(contentsOf: outputURL)
    #expect(exportedData.range(of: Data("unredacted-secret".utf8)) == nil)
    #expect(exportedData.range(of: Data("eXIf".utf8)) == nil)
}

@Test func lowQualityLossyRedactionProducesSecurityWarning() throws {
    let document = try ImageDocument(
        sourceAssetID: AssetID(rawValue: "source"),
        canvas: ImageCanvas(width: 100, height: 100),
        layers: [
            .redaction(
                RedactionLayer(regions: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)])
            )
        ]
    )
    let renderer = ImageDocumentRenderer(useSoftwareRenderer: true)

    #expect(renderer.exportWarning(for: document, format: .jpeg(quality: 0.5)) != nil)
    #expect(renderer.exportWarning(for: document, format: .jpeg(quality: 0.9)) == nil)
    #expect(renderer.exportWarning(for: document, format: .png) == nil)
}

private func checkerboard(width: Int, height: Int) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value: UInt8 = (x + y).isMultiple(of: 2) ? 0 : 255
            let index = (y * width + x) * 4
            bytes[index] = value
            bytes[index + 1] = value
            bytes[index + 2] = value
            bytes[index + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else { throw ImageRenderError.renderFailed }
    return image
}

private func writeSourceWithSensitiveMetadata(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
    else { throw ImageRenderError.exportFailed }
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifUserComment: "unredacted-secret"
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 37.7749,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.4194,
            kCGImagePropertyGPSLongitudeRef: "W",
        ],
        kCGImageDestinationEmbedThumbnail: true,
        kCGImageDestinationLossyCompressionQuality: 1.0,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw ImageRenderError.exportFailed
    }
}

private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let address = buffer.baseAddress,
            let context = CGContext(
                data: address,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return false }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return true
    }
    guard rendered else { throw ImageRenderError.renderFailed }
    return bytes
}

private func assertMeanFilledBlock(
    source: [UInt8],
    exported: [UInt8],
    width: Int,
    x: Int,
    y: Int,
    size: Int
) throws {
    var sums = [Int](repeating: 0, count: 3)
    for row in y..<(y + size) {
        for column in x..<(x + size) {
            let index = (row * width + column) * 4
            for channel in 0..<3 { sums[channel] += Int(source[index + channel]) }
        }
    }
    let means = sums.map { Double($0) / Double(size * size) }
    var exportedColors = Set<[UInt8]>()
    for row in y..<(y + size) {
        for column in x..<(x + size) {
            let index = (row * width + column) * 4
            let before = Array(source[index..<(index + 3)])
            let after = Array(exported[index..<(index + 3)])
            #expect(after != before, "Original pixel survived at \(column),\(row)")
            for channel in 0..<3 {
                #expect(abs(Double(after[channel]) - means[channel]) <= 2.0)
            }
            exportedColors.insert(after)
        }
    }
    #expect(exportedColors.count == 1, "Mean-fill must be uniform inside each block")
}
