import CoreGraphics
import CoreModel
import CoreText
import Foundation

public struct PDFDocumentRenderer: Sendable {
    private let source: PDFiumDocument
    private let fontData: @Sendable (String) -> Data?

    public init(
        source: PDFiumDocument,
        fontData: @escaping @Sendable (String) -> Data? = { _ in nil }
    ) {
        self.source = source
        self.fontData = fontData
    }

    public func render(
        _ document: PDFEditDocument,
        pageID: PDFPageID,
        maxPixelDimension: Int = 1_600
    ) throws -> CGImage {
        guard let page = document.page(pageID) else {
            throw PDFDocumentError.pageNotFound(pageID)
        }
        let outputSize = pixelSize(for: page, maxPixelDimension: maxPixelDimension)
        guard let context = makeContext(width: outputSize.width, height: outputSize.height) else {
            throw PDFEngineError.renderFailed
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))
        if let sourcePageIndex = page.sourcePageIndex {
            let directTextEdits = page.layers.compactMap { layer -> PDFTextLayer? in
                guard case .text(let text) = layer, text.sourceReference != nil else {
                    return nil
                }
                return text
            }
            let base = try source.renderPage(
                at: sourcePageIndex,
                maxPixelDimension: maxPixelDimension,
                rotation: page.rotation,
                sourceTextEdits: directTextEdits,
                fontData: fontData
            )
            context.draw(
                base,
                in: CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
            )
        }
        for layer in page.layers {
            draw(layer, in: context, size: outputSize, page: page)
        }
        guard let image = context.makeImage() else { throw PDFEngineError.renderFailed }
        return image
    }

    /// Exports an atomic, visually flattened PDF. Source pixels beneath a
    /// redaction are absent from the result and source metadata is not copied.
    public func export(_ document: PDFEditDocument, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        if canPreserveSourceContent(document) {
            try source.exportApplyingSourceEdits(
                document,
                to: temporary,
                fontData: fontData
            )
            try install(temporary, at: destination, using: fileManager)
            return
        }
        guard let consumer = CGDataConsumer(url: temporary as CFURL) else {
            throw PDFEngineError.renderFailed
        }
        var firstBox = mediaBox(for: document.pages[0])
        guard let pdf = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else {
            throw PDFEngineError.renderFailed
        }
        for page in document.pages {
            let box = mediaBox(for: page)
            pdf.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
            let image = try render(
                document,
                pageID: page.id,
                maxPixelDimension: max(Int(max(box.width, box.height) * 2), 1)
            )
            pdf.draw(image, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        try install(temporary, at: destination, using: fileManager)
    }

    private func pixelSize(for page: PDFPage, maxPixelDimension: Int) -> (
        width: Int, height: Int
    ) {
        let rotated = page.rotation == .degrees90 || page.rotation == .degrees270
        let width = rotated ? page.size.height : page.size.width
        let height = rotated ? page.size.width : page.size.height
        let scale = min(Double(max(maxPixelDimension, 1)) / max(width, height), 4)
        return (
            width: max(Int((width * scale).rounded()), 1),
            height: max(Int((height * scale).rounded()), 1)
        )
    }

    private func mediaBox(for page: PDFPage) -> CGRect {
        let rotated = page.rotation == .degrees90 || page.rotation == .degrees270
        return CGRect(
            x: 0,
            y: 0,
            width: rotated ? page.size.height : page.size.width,
            height: rotated ? page.size.width : page.size.height
        )
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func draw(
        _ layer: PDFLayer,
        in context: CGContext,
        size: (width: Int, height: Int),
        page: PDFPage
    ) {
        switch layer {
        case .text(let text):
            guard text.sourceReference == nil else { return }
            let rect = outputRect(text.frame, size: size)
            let pointSize = max(text.fontSize / page.size.height * Double(size.height), 1)
            let font = CTFontCreateWithName(text.font.postScriptName as CFString, pointSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(
                    text.color),
            ]
            let framesetter = CTFramesetterCreateWithAttributedString(
                NSAttributedString(string: text.text, attributes: attributes)
            )
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
        case .highlight(let highlight):
            context.setFillColor(color(highlight.color))
            for region in highlight.regions {
                context.fill(outputRect(region, size: size))
            }
        case .redaction(let redaction):
            context.setFillColor(color(redaction.color))
            for region in redaction.regions {
                context.fill(outputRect(region, size: size))
            }
        }
    }

    private func outputRect(
        _ normalized: CGRect,
        size: (width: Int, height: Int)
    ) -> CGRect {
        let width = Double(size.width)
        let height = Double(size.height)
        return CGRect(
            x: normalized.minX * width,
            y: (1 - normalized.maxY) * height,
            width: normalized.width * width,
            height: normalized.height * height
        )
    }

    private func color(_ color: RGBA) -> CGColor {
        CGColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    private func canPreserveSourceContent(_ document: PDFEditDocument) -> Bool {
        guard document.pages.count == source.pageCount else { return false }
        for (index, page) in document.pages.enumerated() {
            guard page.sourcePageIndex == index else { return false }
            guard
                page.layers.allSatisfy({ layer in
                    guard case .text(let text) = layer else { return false }
                    return text.sourceReference != nil
                })
            else { return false }
        }
        return true
    }

    private func install(
        _ temporary: URL,
        at destination: URL,
        using fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
