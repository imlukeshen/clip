import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct PDFKitBackend: ConversionBackend {
    public init() {}

    public var id: BackendID { .pdfKit }
    public var isAvailable: Bool { true }

    public func edges() -> [ConversionEdge] {
        let rasterOptions: ConversionOptionSupport = [
            .pageRange, .rasterizationDPI, .stripMetadata,
        ]
        return [
            ConversionEdge(
                from: .exact(ConversionFormats.pdf), to: ConversionFormats.png,
                backend: id, implementation: .pdfKit, cost: .cheap, isLossless: false,
                warnings: ["PDF pages will be rasterized."], supportedOptions: rasterOptions),
            ConversionEdge(
                from: .exact(ConversionFormats.pdf), to: ConversionFormats.jpeg,
                backend: id, implementation: .pdfKit, cost: .cheap, isLossless: false,
                warnings: ["PDF pages will be rasterized with lossy compression."],
                supportedOptions: rasterOptions.union(.quality)),
            ConversionEdge(
                from: .exact(ConversionFormats.pdf), to: ConversionFormats.plainText,
                backend: id, implementation: .pdfKit, cost: .cheap, isLossless: false),
            ConversionEdge(
                from: .oneOf(ConversionFormats.imageInputs), to: ConversionFormats.pdf,
                backend: id, implementation: .pdfKit, cost: .cheap, isLossless: true,
                supportedOptions: [.stripMetadata]),
        ]
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(0)
                    let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    if step.from.type == ConversionFormats.pdf.type {
                        try Self.exportPDF(input, to: temporary, format: step.to)
                    } else if step.to.type == ConversionFormats.pdf.type {
                        try Self.createPDF(from: input, at: temporary)
                    } else {
                        throw ConversionError.unsupported("Unsupported PDF conversion")
                    }
                    try AtomicOutput.commit(temporary, to: output)
                    continuation.yield(1)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ConversionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func exportPDF(_ input: URL, to output: URL, format: FormatID) throws {
        guard let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw ConversionError.invalidInput
        }
        if format.type == ConversionFormats.plainText.type {
            try Data((document.string ?? "").utf8).write(to: output, options: .atomic)
            return
        }
        guard let page = document.page(at: 0) else { throw ConversionError.invalidInput }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = max(Int(ceil(bounds.width * scale)), 1)
        let height = max(Int(ceil(bounds.height * scale)), 1)
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw ConversionError.cannotCreateOutput }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else {
            throw ConversionError.conversionFailed("PDF rendering failed")
        }
        let type: UTType = format.type == ConversionFormats.jpeg.type ? .jpeg : .png
        guard
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, type.identifier as CFString, 1, nil)
        else {
            throw ConversionError.cannotCreateOutput
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.conversionFailed("PDF image export failed")
        }
    }

    private static func createPDF(from input: URL, at output: URL) throws {
        guard let image = NSImage(contentsOf: input), let page = PDFPage(image: image) else {
            throw ConversionError.invalidInput
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: output) else { throw ConversionError.cannotCreateOutput }
    }
}
