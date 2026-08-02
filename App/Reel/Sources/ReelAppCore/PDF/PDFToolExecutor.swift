import AIKit
import CoreGraphics
import CoreModel
import Foundation

public struct PDFToolExecutionContext: Sendable {
    public var document: PDFEditDocument
    public var selectedPageID: PDFPageID

    public init(document: PDFEditDocument, selectedPageID: PDFPageID) {
        self.document = document
        self.selectedPageID = selectedPageID
    }
}

public struct PDFToolResult: Sendable {
    public var message: String
    public var patches: [PDFPatch]
    public var value: String?

    public init(message: String, patches: [PDFPatch] = [], value: String? = nil) {
        self.message = message
        self.patches = patches
        self.value = value
    }
}

public struct PDFToolExecutor: Sendable {
    public typealias Recognizer =
        @Sendable (PDFEditDocument, PDFPageID) async throws -> String
    public typealias MarkdownConverter = @Sendable (PDFEditDocument) async throws -> String

    private let recognizer: Recognizer
    private let markdownConverter: MarkdownConverter

    public init(
        recognizer: @escaping Recognizer = { _, _ in
            throw PDFToolExecutorError.ocrUnavailable
        },
        markdownConverter: @escaping MarkdownConverter = { _ in
            throw PDFToolExecutorError.markdownUnavailable
        }
    ) {
        self.recognizer = recognizer
        self.markdownConverter = markdownConverter
    }

    public func execute(
        _ invocation: ToolInvocation,
        context: PDFToolExecutionContext
    ) async throws -> PDFToolResult {
        guard let command = CommandRegistry.command(named: invocation.name),
            command.category == .pdf
        else { throw PDFToolExecutorError.unknownTool(invocation.name) }

        switch invocation.name {
        case "pdf.describe":
            let editCount = context.document.pages.reduce(0) { $0 + $1.layers.count }
            let ocrCount = context.document.pages.count { $0.ocrText != nil }
            return PDFToolResult(
                message:
                    "\(context.document.pages.count) pages, \(editCount) edits, and \(ocrCount) OCR pages."
            )

        case "pdf.addText":
            let arguments = try invocation.arguments.decode(TextArguments.self)
            let pageID = try pageID(arguments.pageID, context: context)
            let layer = PDFLayer.text(
                PDFTextLayer(
                    text: arguments.text,
                    frame: arguments.rect.cgRect,
                    fontSize: arguments.fontSize ?? 14
                )
            )
            return try add(layer, to: pageID, context: context, message: "Prepared PDF text.")

        case "pdf.highlight":
            let arguments = try invocation.arguments.decode(RegionArguments.self)
            let pageID = try pageID(arguments.pageID, context: context)
            return try add(
                .highlight(PDFHighlightLayer(regions: [arguments.rect.cgRect])),
                to: pageID,
                context: context,
                message: "Prepared a PDF highlight."
            )

        case "pdf.redact":
            let arguments = try invocation.arguments.decode(RegionArguments.self)
            let pageID = try pageID(arguments.pageID, context: context)
            return try add(
                .redaction(PDFRedactionLayer(regions: [arguments.rect.cgRect])),
                to: pageID,
                context: context,
                message: "Prepared a PDF redaction."
            )

        case "pdf.rotatePage":
            let arguments = try invocation.arguments.decode(PageArguments.self)
            let pageID = try pageID(arguments.pageID, context: context)
            guard var page = context.document.page(pageID) else {
                throw PDFToolExecutorError.pageNotFound(pageID.rawValue)
            }
            page.rotation = page.rotation.rotatedClockwise()
            return PDFToolResult(
                message: "Prepared a clockwise page rotation.", patches: [.updatePage(page)])

        case "pdf.reorderPage":
            let arguments = try invocation.arguments.decode(ReorderArguments.self)
            let pageID = try pageID(arguments.pageID, context: context)
            let destination = Int(arguments.destination.rounded(.towardZero))
            guard context.document.pages.indices.contains(destination) else {
                throw PDFToolExecutorError.invalidArguments("Destination is outside the document.")
            }
            return PDFToolResult(
                message: "Prepared a page reorder.",
                patches: [.reorderPage(pageID, to: destination)]
            )

        case "pdf.ocrPage":
            let arguments = try invocation.arguments.decode(PageArguments.self)
            let pageID = try pageID(arguments.pageID, context: context)
            let text = try await recognizer(context.document, pageID)
            return PDFToolResult(
                message: text.isEmpty
                    ? "No text was found on this page." : "Recognized this page on device.",
                patches: [.setOCRText(text, on: pageID)],
                value: text
            )

        case "pdf.toMarkdown":
            let markdown = try await markdownConverter(context.document)
            return PDFToolResult(message: "Converted the PDF to Markdown.", value: markdown)

        default:
            throw PDFToolExecutorError.unknownTool(invocation.name)
        }
    }

    private func add(
        _ layer: PDFLayer,
        to pageID: PDFPageID,
        context: PDFToolExecutionContext,
        message: String
    ) throws -> PDFToolResult {
        guard let page = context.document.page(pageID) else {
            throw PDFToolExecutorError.pageNotFound(pageID.rawValue)
        }
        return PDFToolResult(
            message: message,
            patches: [.addLayer(layer, to: pageID, atIndex: page.layers.count)]
        )
    }

    private func pageID(
        _ value: String?,
        context: PDFToolExecutionContext
    ) throws -> PDFPageID {
        let id = value.map(PDFPageID.init(rawValue:)) ?? context.selectedPageID
        guard context.document.page(id) != nil else {
            throw PDFToolExecutorError.pageNotFound(id.rawValue)
        }
        return id
    }
}

public enum PDFToolExecutorError: Error, Sendable, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
    case pageNotFound(String)
    case ocrUnavailable
    case markdownUnavailable
}

private struct RectArguments: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct PageArguments: Codable {
    var pageID: String?
}

private struct TextArguments: Codable {
    var pageID: String?
    var text: String
    var rect: RectArguments
    var fontSize: Double?
}

private struct RegionArguments: Codable {
    var pageID: String?
    var rect: RectArguments
}

private struct ReorderArguments: Codable {
    var pageID: String?
    var destination: Double
}
