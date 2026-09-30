import CoreModel
import Foundation

/// Where a run of text sits on a PDF page.
///
/// The gap this fills: `pdf.redact` takes a rectangle, and nothing told the
/// assistant where a word was. Asked to redact a name it could describe the
/// document, convert it to Markdown, or read its text — and none of those
/// answers contained a coordinate, so the rectangle had to be invented or the
/// request abandoned. Matching is done over glyphs rather than spans because a
/// PDF span is a whole formatting run: redacting the span that contains a name
/// blacks out the sentence around it.
public struct PDFTextMatch: Sendable, Equatable {
    public let pageID: PDFPageID
    /// Normalized page coordinates with an upper-left origin.
    public let rect: CGRect
    /// The surrounding text, so a person can tell matches apart before applying.
    public let snippet: String

    public init(pageID: PDFPageID, rect: CGRect, snippet: String) {
        self.pageID = pageID
        self.rect = rect
        self.snippet = snippet
    }
}

/// Locates a string across a PDF's pages.
public typealias PDFTextLocating =
    @Sendable (PDFEditDocument, String, PDFPageID?) async throws ->
    [PDFTextMatch]
