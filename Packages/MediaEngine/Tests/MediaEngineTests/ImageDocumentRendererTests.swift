import CoreGraphics
import CoreModel
import Foundation
import Testing

@testable import MediaEngine

@Test func allSevenImageLayersShareOnePreviewAndExportPipeline() throws {
    let source = try stripedImage(width: 96, height: 64)
    let layers: [Layer] = [
        .padding(PaddingLayer(id: LayerID(rawValue: "padding"), amount: 0.05, cornerRadius: 4)),
        .annotation(
            AnnotationLayer(
                id: LayerID(rawValue: "annotation"),
                kind: .arrow,
                points: [CGPoint(x: 0.08, y: 0.15), CGPoint(x: 0.35, y: 0.3)],
                bounds: CGRect(x: 0.08, y: 0.15, width: 0.27, height: 0.15)
            )
        ),
        .text(TextLayer(id: LayerID(rawValue: "text"), text: "Reel", frame: CGRect(x: 0.5, y: 0.08, width: 0.4, height: 0.2), fontSize: 12)),
        .highlight(HighlightLayer(id: LayerID(rawValue: "highlight"), regions: [CGRect(x: 0.05, y: 0.55, width: 0.2, height: 0.18)])),
        .redaction(RedactionLayer(id: LayerID(rawValue: "redaction"), regions: [CGRect(x: 0.3, y: 0.55, width: 0.2, height: 0.2)], style: .pixelate(size: 4))),
        .blur(BlurLayer(id: LayerID(rawValue: "blur"), regions: [CGRect(x: 0.55, y: 0.55, width: 0.18, height: 0.2)], radius: 3)),
        .step(StepLayer(id: LayerID(rawValue: "step"), number: 1, position: CGPoint(x: 0.86, y: 0.68), diameter: 18)),
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
