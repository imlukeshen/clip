import AppKit
import CoreImage
import CoreModel
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExportFormat: Sendable, Equatable {
    case png
    case jpeg(quality: Double)
    case heic(quality: Double)

    fileprivate var typeIdentifier: String {
        switch self {
        case .png: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .heic: UTType.heic.identifier
        }
    }

    fileprivate var properties: CFDictionary {
        var properties: [CFString: Any] = [
            kCGImageDestinationEmbedThumbnail: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        switch self {
        case .png: break
        case .jpeg(let quality), .heic(let quality):
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        return properties as CFDictionary
    }

    fileprivate var isLowQualityLossy: Bool {
        switch self {
        case .png: false
        case .jpeg(let quality), .heic(let quality): quality < 0.8
        }
    }
}

public enum ImageRenderError: Error, Sendable, Equatable {
    case unreadableSource
    case invalidOutputSize
    case renderFailed
    case exportFailed
}

/// One deterministic Core Image stack shared by editor previews and flattened exports.
public final class ImageDocumentRenderer: @unchecked Sendable {
    private let context: CIContext

    public init(useSoftwareRenderer: Bool = false) {
        context = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: useSoftwareRenderer,
        ])
    }

    public func renderPreview(
        _ document: ImageDocument,
        sourceURL: URL,
        pixelSize: CGSize? = nil
    ) throws -> CGImage {
        guard let source = CIImage(
            contentsOf: sourceURL,
            options: [.applyOrientationProperty: true]
        ) else { throw ImageRenderError.unreadableSource }
        return try render(document, source: source, pixelSize: pixelSize)
    }

    public func renderPreview(
        _ document: ImageDocument,
        source: CGImage,
        pixelSize: CGSize? = nil
    ) throws -> CGImage {
        try render(document, source: CIImage(cgImage: source), pixelSize: pixelSize)
    }

    public func renderForExport(
        _ document: ImageDocument,
        sourceURL: URL
    ) throws -> CGImage {
        try renderPreview(document, sourceURL: sourceURL, pixelSize: document.canvas.size)
    }

    public func renderForExport(
        _ document: ImageDocument,
        source: CGImage
    ) throws -> CGImage {
        try renderPreview(document, source: source, pixelSize: document.canvas.size)
    }

    /// Writes only flattened pixels. Source EXIF, GPS, thumbnails, and layer data are never copied.
    public func export(
        _ document: ImageDocument,
        sourceURL: URL,
        to destinationURL: URL,
        format: ImageExportFormat
    ) throws {
        let image = try renderForExport(document, sourceURL: sourceURL)
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            format.typeIdentifier as CFString,
            1,
            nil
        ) else { throw ImageRenderError.exportFailed }
        CGImageDestinationAddImageAndMetadata(destination, image, nil, format.properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageRenderError.exportFailed
        }
        try stripSensitiveMetadata(at: destinationURL, format: format)
    }

    public func exportWarning(
        for document: ImageDocument,
        format: ImageExportFormat
    ) -> String? {
        guard format.isLowQualityLossy,
            document.layers.contains(where: { layer in
                if case .redaction = layer { return true }
                return false
            })
        else { return nil }
        return "Low-quality lossy compression can reveal redaction edges. Use PNG or quality 80%+."
    }

    private func render(
        _ document: ImageDocument,
        source: CIImage,
        pixelSize requestedSize: CGSize?
    ) throws -> CGImage {
        try document.validate()
        let size = requestedSize ?? document.canvas.size
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            throw ImageRenderError.invalidOutputSize
        }
        let bounds = CGRect(origin: .zero, size: size.integralSize)
        let background = CIImage(color: document.canvas.background.ciColor).cropped(to: bounds)
        var image = prepareSource(
            source,
            geometry: document.geometry,
            orientation: document.canvas.orientation,
            bounds: bounds
        ).composited(over: background)

        for layer in document.layers where layer.isVisible {
            switch layer {
            case .annotation(let value):
                image = try overlay(value, over: image, bounds: bounds)
            case .text(let value):
                image = try overlay(value, over: image, bounds: bounds)
            case .highlight(let value):
                image = overlay(value, over: image, bounds: bounds)
            case .redaction(let value):
                image = redact(value, in: image, bounds: bounds)
            case .blur(let value):
                image = blur(value, in: image, bounds: bounds)
            case .padding(let value):
                image = padding(value, around: image, bounds: bounds)
            case .step(let value):
                image = try overlay(value, over: image, bounds: bounds)
            }
        }

        guard let rendered = context.createCGImage(
            image.cropped(to: bounds),
            from: bounds,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) else { throw ImageRenderError.renderFailed }
        return rendered
    }

    private func prepareSource(
        _ source: CIImage,
        geometry: Geometry,
        orientation: ImageOrientation,
        bounds: CGRect
    ) -> CIImage {
        let extent = source.extent
        let normalized = geometry.crop
        let crop = CGRect(
            x: extent.minX + normalized.minX * extent.width,
            y: extent.minY + (1 - normalized.maxY) * extent.height,
            width: normalized.width * extent.width,
            height: normalized.height * extent.height
        ).intersection(extent)
        var image = source.cropped(to: crop).transformed(
            by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        )
        let width = image.extent.width
        let height = image.extent.height
        if geometry.isFlippedHorizontally {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0))
        }
        if geometry.isFlippedVertically {
            image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))
        }
        let orientationDegrees: Double
        switch orientation {
        case .up: orientationDegrees = 0
        case .right: orientationDegrees = -90
        case .down: orientationDegrees = 180
        case .left: orientationDegrees = 90
        }
        let radians = (geometry.rotationDegrees + orientationDegrees) * .pi / 180
        if radians != 0 {
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            image = image.transformed(by: transform)
            image = image.transformed(
                by: CGAffineTransform(
                    translationX: -image.extent.minX,
                    y: -image.extent.minY
                )
            )
        }
        let fit = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
            * geometry.scale
        image = image.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        return image.transformed(
            by: CGAffineTransform(
                translationX: bounds.midX - image.extent.midX,
                y: bounds.midY - image.extent.midY
            )
        ).cropped(to: bounds)
    }

    private func overlay(
        _ layer: AnnotationLayer,
        over image: CIImage,
        bounds: CGRect
    ) throws -> CIImage {
        try vectorOverlay(bounds: bounds) { context in
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(layer.strokeWidth)
            context.setStrokeColor(layer.strokeColor.cgColor)
            if let fill = layer.fillColor { context.setFillColor(fill.cgColor) }
            let rect = layer.bounds.renderRect(in: bounds)
            switch layer.kind {
            case .box:
                if layer.fillColor != nil { context.fill(rect) }
                context.stroke(rect)
            case .ellipse:
                if layer.fillColor != nil { context.fillEllipse(in: rect) }
                context.strokeEllipse(in: rect)
            case .line, .arrow:
                let start = layer.points.first?.renderPoint(in: bounds)
                    ?? CGPoint(x: rect.minX, y: rect.minY)
                let end = layer.points.last?.renderPoint(in: bounds)
                    ?? CGPoint(x: rect.maxX, y: rect.maxY)
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
                if layer.kind == .arrow { drawArrowhead(context, from: start, to: end, width: layer.strokeWidth) }
            case .freehand:
                guard let first = layer.points.first else { return }
                context.move(to: first.renderPoint(in: bounds))
                for point in layer.points.dropFirst() {
                    context.addLine(to: point.renderPoint(in: bounds))
                }
                context.strokePath()
            }
        }.composited(over: image)
    }

    private func overlay(_ layer: TextLayer, over image: CIImage, bounds: CGRect) throws -> CIImage {
        try vectorOverlay(bounds: bounds) { context in
            let frame = layer.frame.renderRect(in: bounds)
            let font = CTFontCreateWithName(layer.fontName as CFString, layer.fontSize, nil)
            let attributed = NSAttributedString(
                string: layer.text,
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: layer.color.cgColor,
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x: CGFloat
            switch layer.alignment {
            case .leading: x = frame.minX
            case .center: x = frame.midX - width / 2
            case .trailing: x = frame.maxX - width
            }
            context.textPosition = CGPoint(x: x, y: frame.midY - layer.fontSize / 2)
            CTLineDraw(line, context)
        }.composited(over: image)
    }

    private func overlay(_ layer: HighlightLayer, over image: CIImage, bounds: CGRect) -> CIImage {
        layer.regions.reduce(image) { result, region in
            CIImage(color: layer.color.ciColor)
                .cropped(to: region.renderRect(in: bounds))
                .composited(over: result)
        }
    }

    private func overlay(_ layer: StepLayer, over image: CIImage, bounds: CGRect) throws -> CIImage {
        try vectorOverlay(bounds: bounds) { context in
            let center = layer.position.renderPoint(in: bounds)
            let rect = CGRect(
                x: center.x - layer.diameter / 2,
                y: center.y - layer.diameter / 2,
                width: layer.diameter,
                height: layer.diameter
            )
            context.setFillColor(layer.fillColor.cgColor)
            context.fillEllipse(in: rect)
            let font = CTFontCreateWithName("SF Pro Rounded Semibold" as CFString, layer.diameter * 0.52, nil)
            let attributed = NSAttributedString(
                string: String(layer.number),
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: layer.textColor.cgColor,
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            let textBounds = CTLineGetBoundsWithOptions(line, [])
            context.textPosition = CGPoint(
                x: center.x - textBounds.width / 2 - textBounds.minX,
                y: center.y - textBounds.height / 2 - textBounds.minY
            )
            CTLineDraw(line, context)
        }.composited(over: image)
    }

    private func blur(_ layer: BlurLayer, in image: CIImage, bounds: CGRect) -> CIImage {
        layer.regions.reduce(image) { result, normalized in
            let region = normalized.renderRect(in: bounds)
            let blurred = result.clampedToExtent().applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: layer.radius]
            ).cropped(to: region)
            return blurred.composited(over: result)
        }
    }

    private func redact(_ layer: RedactionLayer, in image: CIImage, bounds: CGRect) -> CIImage {
        layer.regions.reduce(image) { result, normalized in
            let region = normalized.renderRect(in: bounds).integral.intersection(bounds)
            switch layer.style {
            case .solid(let color):
                return CIImage(color: color.ciColor).cropped(to: region).composited(over: result)
            case .blur(let radius):
                let blurred = result.clampedToExtent().applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: radius]
                ).cropped(to: region)
                return blurred.composited(over: result)
            case .pixelate(let size):
                return meanPixelate(result, region: region, blockSize: size)
            }
        }
    }

    /// Replaces every output block with its exact area mean instead of resampling source detail.
    private func meanPixelate(_ image: CIImage, region: CGRect, blockSize: Int) -> CIImage {
        var result = image
        let block = CGFloat(max(blockSize, 1))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var y = region.minY
        while y < region.maxY {
            var x = region.minX
            while x < region.maxX {
                let rect = CGRect(
                    x: x,
                    y: y,
                    width: min(block, region.maxX - x),
                    height: min(block, region.maxY - y)
                )
                let width = max(Int(rect.width.rounded()), 1)
                let height = max(Int(rect.height.rounded()), 1)
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                pixels.withUnsafeMutableBytes { buffer in
                    guard let address = buffer.baseAddress else { return }
                    context.render(
                        image,
                        toBitmap: address,
                        rowBytes: width * 4,
                        bounds: rect,
                        format: .RGBA8,
                        colorSpace: colorSpace
                    )
                }
                var sums = [UInt64](repeating: 0, count: 4)
                for index in stride(from: 0, to: pixels.count, by: 4) {
                    for channel in 0..<4 { sums[channel] += UInt64(pixels[index + channel]) }
                }
                let count = Double(width * height) * 255
                let color = CIColor(
                    red: Double(sums[0]) / count,
                    green: Double(sums[1]) / count,
                    blue: Double(sums[2]) / count,
                    alpha: Double(sums[3]) / count
                )
                let filled = CIImage(color: color).cropped(to: rect)
                result = filled.composited(over: result)
                x += block
            }
            y += block
        }
        return result
    }

    private func padding(_ layer: PaddingLayer, around image: CIImage, bounds: CGRect) -> CIImage {
        let inset = min(
            CGFloat(layer.amount) * min(bounds.width, bounds.height),
            min(bounds.width, bounds.height) / 2 - 1
        )
        let target = bounds.insetBy(dx: inset, dy: inset)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        let framed = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        ).transformed(
            by: CGAffineTransform(
                translationX: target.midX - image.extent.midX * scale,
                y: target.midY - image.extent.midY * scale
            )
        )
        let background = CIImage(color: layer.color.ciColor).cropped(to: bounds)
        let mask = roundedMask(extent: target, radius: layer.cornerRadius)
        let transparent = CIImage(color: .clear).cropped(to: bounds)
        let clipped = framed.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: mask,
            ]
        )
        var underlay = background
        if let shadow = layer.shadow {
            let shadowMask = mask.clampedToExtent().applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: shadow.radius]
            ).cropped(to: bounds).transformed(
                by: CGAffineTransform(translationX: shadow.offset.x, y: -shadow.offset.y)
            )
            let shadowImage = CIImage(color: shadow.color.ciColor).cropped(to: bounds).applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: transparent,
                    kCIInputMaskImageKey: shadowMask,
                ]
            )
            underlay = shadowImage.composited(over: background)
        }
        return clipped.composited(over: underlay)
    }

    private func roundedMask(extent: CGRect, radius: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: .white).cropped(to: extent)
        }
        filter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: "inputColor")
        return filter.outputImage?.cropped(to: extent)
            ?? CIImage(color: .white).cropped(to: extent)
    }

    private func vectorOverlay(
        bounds: CGRect,
        draw: (CGContext) -> Void
    ) throws -> CIImage {
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageRenderError.renderFailed }
        draw(context)
        guard let image = context.makeImage() else { throw ImageRenderError.renderFailed }
        return CIImage(cgImage: image)
    }

    private func drawArrowhead(
        _ context: CGContext,
        from start: CGPoint,
        to end: CGPoint,
        width: Double
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(CGFloat(width) * 4, 12)
        context.move(to: end)
        context.addLine(
            to: CGPoint(
                x: end.x - length * cos(angle - .pi / 6),
                y: end.y - length * sin(angle - .pi / 6)
            )
        )
        context.move(to: end)
        context.addLine(
            to: CGPoint(
                x: end.x - length * cos(angle + .pi / 6),
                y: end.y - length * sin(angle + .pi / 6)
            )
        )
        context.strokePath()
    }

    private func stripSensitiveMetadata(at url: URL, format: ImageExportFormat) throws {
        let data = try Data(contentsOf: url)
        let sanitized: Data
        switch format {
        case .png:
            sanitized = stripPNGMetadata(data)
        case .jpeg:
            sanitized = stripJPEGMetadata(data)
        case .heic:
            // ImageIO receives nil metadata with GPS/XMP exclusion and thumbnail embedding off.
            sanitized = data
        }
        try sanitized.write(to: url, options: .atomic)
    }

    private func stripPNGMetadata(_ data: Data) -> Data {
        let signatureCount = 8
        guard data.count >= signatureCount else { return data }
        let strippedTypes: Set<String> = ["eXIf", "tEXt", "zTXt", "iTXt"]
        var result = Data(data.prefix(signatureCount))
        var index = signatureCount
        while index + 12 <= data.count {
            let length = Int(bigEndianUInt32(in: data, at: index))
            let end = index + 12 + length
            guard end <= data.count else { return data }
            let typeRange = (index + 4)..<(index + 8)
            let type = String(data: data[typeRange], encoding: .ascii) ?? ""
            if !strippedTypes.contains(type) {
                result.append(data[index..<end])
            }
            index = end
            if type == "IEND" { break }
        }
        return result
    }

    private func stripJPEGMetadata(_ data: Data) -> Data {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return data }
        var result = Data(data.prefix(2))
        var index = 2
        while index + 4 <= data.count {
            guard data[index] == 0xFF else { return data }
            let marker = data[index + 1]
            if marker == 0xDA {
                result.append(data[index...])
                return result
            }
            if marker == 0xD9 {
                result.append(data[index...])
                return result
            }
            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            let end = index + 2 + length
            guard length >= 2, end <= data.count else { return data }
            let isMetadata = (0xE0...0xEF).contains(marker) || marker == 0xFE
            if !isMetadata { result.append(data[index..<end]) }
            index = end
        }
        return result
    }

    private func bigEndianUInt32(in data: Data, at index: Int) -> UInt32 {
        UInt32(data[index]) << 24
            | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
    }
}

extension ImageCanvas {
    fileprivate var size: CGSize { CGSize(width: width, height: height) }
}

extension CGSize {
    fileprivate var integralSize: CGSize {
        CGSize(width: width.rounded(), height: height.rounded())
    }
}

extension CGRect {
    fileprivate func renderRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + minX * bounds.width,
            y: bounds.minY + (1 - maxY) * bounds.height,
            width: width * bounds.width,
            height: height * bounds.height
        )
    }
}

extension CGPoint {
    fileprivate func renderPoint(in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.minX + x * bounds.width,
            y: bounds.minY + (1 - y) * bounds.height
        )
    }
}

extension RGBA {
    fileprivate var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }
    fileprivate var cgColor: CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
}
