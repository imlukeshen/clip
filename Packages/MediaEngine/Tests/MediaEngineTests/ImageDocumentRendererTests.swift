import CoreGraphics
import CoreModel
import Foundation
import ImageIO
import Testing

@testable import MediaEngine

@Test func allEightImageLayersShareOnePreviewAndExportPipeline() throws {
    let source = try stripedImage(width: 96, height: 64)
    let rasterSource = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-raster-layer-\(UUID().uuidString).png"
    )
    try writePNG(
        try solidImage(width: 16, height: 16, red: 255, green: 0, blue: 180), to: rasterSource)
    defer { try? FileManager.default.removeItem(at: rasterSource) }
    let layers: [Layer] = [
        .padding(PaddingLayer(id: LayerID(rawValue: "padding"), amount: 0.05, cornerRadius: 4)),
        .raster(
            RasterLayer(
                id: LayerID(rawValue: "raster"),
                name: "Overlay",
                sourceURL: rasterSource,
                frame: CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.3),
                rotationDegrees: 12,
                opacity: 0.8,
                blendMode: .screen
            )
        ),
        .annotation(
            AnnotationLayer(
                id: LayerID(rawValue: "annotation"),
                kind: .arrow,
                points: [CGPoint(x: 0.08, y: 0.15), CGPoint(x: 0.35, y: 0.3)],
                bounds: CGRect(x: 0.08, y: 0.15, width: 0.27, height: 0.15)
            )
        ),
        .text(
            TextLayer(
                id: LayerID(rawValue: "text"), text: "Reel",
                frame: CGRect(x: 0.5, y: 0.08, width: 0.4, height: 0.2), fontSize: 12)),
        .highlight(
            HighlightLayer(
                id: LayerID(rawValue: "highlight"),
                regions: [CGRect(x: 0.05, y: 0.55, width: 0.2, height: 0.18)])),
        .redaction(
            RedactionLayer(
                id: LayerID(rawValue: "redaction"),
                regions: [CGRect(x: 0.3, y: 0.55, width: 0.2, height: 0.2)],
                style: .pixelate(size: 4))),
        .blur(
            BlurLayer(
                id: LayerID(rawValue: "blur"),
                regions: [CGRect(x: 0.55, y: 0.55, width: 0.18, height: 0.2)], radius: 3)),
        .step(
            StepLayer(
                id: LayerID(rawValue: "step"), number: 1, position: CGPoint(x: 0.86, y: 0.68),
                diameter: 18)),
    ]
    let document = try ImageDocument(
        sourceAssetID: AssetID(rawValue: "source"),
        canvas: ImageCanvas(width: 96, height: 64),
        layers: layers
    )
    let renderer = ImageDocumentRenderer(useSoftwareRenderer: true)

    let preview = try renderer.renderPreview(
        document,
        source: source,
        pixelSize: CGSize(width: 96, height: 64)
    )
    let exported = try renderer.renderForExport(document, source: source)

    #expect(try pixels(preview) == pixels(exported))
    #expect(try pixels(exported) != pixels(source))
}

@Test func rasterLayerOrderTransformAndOpacityFlattenDeterministically() throws {
    let source = try solidImage(width: 20, height: 20, red: 0, green: 0, blue: 0)
    let redURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-raster-red-\(UUID().uuidString).png"
    )
    let blueURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-raster-blue-\(UUID().uuidString).png"
    )
    defer {
        try? FileManager.default.removeItem(at: redURL)
        try? FileManager.default.removeItem(at: blueURL)
    }
    try writePNG(try solidImage(width: 4, height: 4, red: 255, green: 0, blue: 0), to: redURL)
    try writePNG(try solidImage(width: 4, height: 4, red: 0, green: 0, blue: 255), to: blueURL)
    let frame = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let document = try ImageDocument(
        sourceAssetID: AssetID(rawValue: "raster-source"),
        canvas: ImageCanvas(width: 20, height: 20),
        layers: [
            .raster(RasterLayer(name: "Red", sourceURL: redURL, frame: frame)),
            .raster(
                RasterLayer(
                    name: "Blue", sourceURL: blueURL, frame: frame,
                    opacity: 0.5
                )
            ),
        ]
    )
    let rendered = try ImageDocumentRenderer(useSoftwareRenderer: true).renderForExport(
        document,
        source: source
    )
    let bytes = try pixels(rendered)
    let center = (10 * 20 + 10) * 4
    #expect(bytes[center] > 100)
    #expect(bytes[center + 2] > 100)
    #expect(bytes[center + 1] < 10)
}

@Test func selectedLayerPreviewIsTransparentAndCroppedToItsCanvasFrame() throws {
    let rasterURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-selected-layer-\(UUID().uuidString).png"
    )
    defer { try? FileManager.default.removeItem(at: rasterURL) }
    try writePNG(
        try solidImage(width: 8, height: 8, red: 40, green: 120, blue: 240),
        to: rasterURL
    )
    let layer = Layer.raster(
        RasterLayer(
            name: "Selected",
            sourceURL: rasterURL,
            frame: CGRect(x: 0.2, y: 0.25, width: 0.4, height: 0.3),
            rotationDegrees: 37
        )
    )

    let preview = try ImageDocumentRenderer(useSoftwareRenderer: true).renderLayerPreview(
        layer,
        canvas: ImageCanvas(width: 100, height: 80)
    )

    #expect(preview.width == 40)
    #expect(preview.height == 24)
    let bytes = try pixels(preview)
    #expect(bytes.contains(where: { $0 != 0 }))
}

private func stripedImage(width: Int, height: Int) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            bytes[index] = UInt8((x * 255) / max(width - 1, 1))
            bytes[index + 1] = UInt8((y * 255) / max(height - 1, 1))
            bytes[index + 2] = x.isMultiple(of: 2) ? 255 : 0
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

private func solidImage(
    width: Int,
    height: Int,
    red: UInt8,
    green: UInt8,
    blue: UInt8
) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: bytes.count, by: 4) {
        bytes[index] = red
        bytes[index + 1] = green
        bytes[index + 2] = blue
        bytes[index + 3] = 255
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

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else { throw ImageRenderError.exportFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageRenderError.exportFailed }
}

private func pixels(_ image: CGImage) throws -> Data {
    let width = image.width
    let height = image.height
    var bytes = Data(count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let address = buffer.baseAddress,
            let context = CGContext(
                data: address,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw ImageRenderError.renderFailed }
    return bytes
}
