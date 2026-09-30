import AIKit
import CoreGraphics
import CoreModel
import Foundation

public struct PDFToolExecutionContext: Sendable {
    public var document: PDFEditDocument
    public var selectedPageID: PDFPageID
    /// Resolves a string to the rectangles it occupies, so the assistant can
    /// redact something it was named rather than something it was measured.
    public var locatingText: PDFTextLocating

    public init(
        document: PDFEditDocument,
        selectedPageID: PDFPageID,
        locatingText: @escaping PDFTextLocating = { _, _, _ in [] }
    ) {
        self.document = document
        self.selectedPageID = selectedPageID
        self.locatingText = locatingText
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

        case "pdf.findText":
            let arguments = try invocation.arguments.decode(FindArguments.self)
            let matches = try await context.locatingText(
                context.document, arguments.text, Self.searchPage(arguments.pageID, in: context))
            guard !matches.isEmpty else {
                return PDFToolResult(
                    message: "No occurrence of \"\(arguments.text)\" in "
                        + Self.scope(arguments.pageID, in: context) + ".")
            }
            return PDFToolResult(message: Self.describe(matches), value: Self.describe(matches))

        case "pdf.redactText":
            let arguments = try invocation.arguments.decode(FindArguments.self)
            let matches = try await context.locatingText(
                context.document, arguments.text, Self.searchPage(arguments.pageID, in: context))
            guard !matches.isEmpty else {
                // Says where it looked. "Not in this document" was true of the
                // pages actually searched and false of the document, which is
                // the kind of answer that sends everyone hunting in the wrong
                // place.
                return PDFToolResult(
                    message: "Nothing was redacted: \"\(arguments.text)\" was not found in "
                        + Self.scope(arguments.pageID, in: context) + ".")
            }
            // One layer per match. A layer is the unit of selection and
            // deletion, so one layer holding every match made the run
            // all-or-nothing: an occurrence redacted by mistake could only be
            // removed by taking back the rest. Each page is still one patch, so
            // the request remains a single undo.
            let byPage = Dictionary(grouping: matches, by: \.pageID)
            var patches: [PDFPatch] = []
            for (pageID, pageMatches) in byPage.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                guard var page = context.document.page(pageID) else { continue }
                for match in pageMatches {
                    page.layers.append(.redaction(PDFRedactionLayer(regions: [match.rect])))
                }
                patches.append(.updatePage(page))
            }
            let count = matches.count
            return PDFToolResult(
                message:
                    "Prepared \(count) redaction\(count == 1 ? "" : "s") of \"\(arguments.text)\".",
                patches: patches
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

extension PDFToolExecutor {
    /// Renders matches as text the model can act on without further lookups.
    ///
    /// Rounded to four places: a normalized page coordinate is precise to well
    /// under a pixel there, and full double precision is a page of digits the
    /// model has to carry through its next call.
    static func describe(_ matches: [PDFTextMatch]) -> String {
        let lines = matches.map { match in
            let rect = match.rect
            return "page \(match.pageID.rawValue) "
                + "rect [\(round(rect.minX)), \(round(rect.minY)), "
                + "\(round(rect.width)), \(round(rect.height))] — \(match.snippet)"
        }
        return "Found \(matches.count) match\(matches.count == 1 ? "" : "es"):\n"
            + lines.joined(separator: "\n")
    }

    private static func round(_ value: CGFloat) -> String {
        String(format: "%.4f", value)
    }

    /// The page to restrict a search to, or nil for the whole document.
    ///
    /// A page id that names no page means the whole document, not no document.
    /// Page ids are opaque and a model cannot know one without calling
    /// `pdf.findText` first, so asked to redact a word it reasonably fills the
    /// optional in with "1" or "page 1" — and passing that straight through
    /// searched zero pages and reported the word absent from a document it was
    /// plainly in.
    /// Describes what a search covered, for a message that can be acted on.
    static func scope(_ requested: String?, in context: PDFToolExecutionContext) -> String {
        guard let page = searchPage(requested, in: context),
            let index = context.document.pages.firstIndex(where: { $0.id == page })
        else {
            let count = context.document.pages.count
            return "any of the \(count) page\(count == 1 ? "" : "s")"
        }
        return "page \(index + 1)"
    }

    static func searchPage(_ value: String?, in context: PDFToolExecutionContext) -> PDFPageID? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let id = PDFPageID(rawValue: value)
        return context.document.page(id) != nil ? id : nil
    }
}

private struct PageArguments: Codable {
    var pageID: String?
}

private struct FindArguments: Codable {
    var text: String
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
