import CoreGraphics
import CoreModel
import CoreText
import Foundation
import Testing

@testable import PDFEngine

@Suite("PDF page text index")
struct PDFPageTextIndexTests {
    @Test("Runs split by formatting rejoin into one paragraph")
    func mixedFormattingFormsOneParagraph() throws {
        let source = try PDFiumDocument(data: mixedFormattingPDF())
        let index = PDFPageTextIndex.build(from: try source.analyzePage(at: 0))

        #expect(index.paragraphs.count == 1)
        let paragraph = try #require(index.paragraphs.first)
        // Three separate PDF text objects, one editable paragraph.
        #expect(paragraph.pageObjectIndexes.count == 3)
        #expect(paragraph.text.contains("Our company provides an"))
        #expect(paragraph.text.contains("open-source platform"))
        #expect(paragraph.text.contains("focus on delegation"))
    }

    @Test("A bold run on the same baseline stays on its line")
    func boldRunSharesItsLine() throws {
        let source = try PDFiumDocument(data: mixedFormattingPDF())
        let index = PDFPageTextIndex.build(from: try source.analyzePage(at: 0))
        let paragraph = try #require(index.paragraphs.first)

        #expect(paragraph.lines.count == 2)
        let first = try #require(paragraph.lines.first)
        // The roman lead-in and the bold phrase are different objects but one line.
        #expect(first.spans.count >= 2)
        #expect(Set(first.spans.map(\.pageObjectIndex)).count >= 2)
        #expect(first.text.contains("Our company provides an"))
        #expect(first.text.contains("open-source platform"))
    }

    @Test("A click anywhere in the paragraph resolves to the whole paragraph")
    func pointResolvesToParagraph() throws {
        let source = try PDFiumDocument(data: mixedFormattingPDF())
        let index = PDFPageTextIndex.build(from: try source.analyzePage(at: 0))
        let paragraph = try #require(index.paragraphs.first)

        // Aim at the bold phrase; the paragraph, not the bold object, comes back.
        let boldSpan = try #require(
            paragraph.spans.first { $0.text.contains("open-source") }
        )
        let hit = try #require(index.paragraph(containing: CGPoint(
            x: boldSpan.bounds.midX,
            y: boldSpan.bounds.midY
        )))
        #expect(hit.id == paragraph.id)
        #expect(hit.pageObjectIndexes.count == 3)
    }

    /// One visual paragraph split across three text objects by formatting and
    /// line wrapping, which is how a real PDF stores prose.
    private func mixedFormattingPDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))

        context.beginPDFPage(nil)
        draw("Our company provides an ", face: "Helvetica", at: CGPoint(x: 20, y: 160), in: context)
        draw("open-source platform", face: "Helvetica-Bold", at: CGPoint(x: 150, y: 160), in: context)
        draw(
            "with a particular focus on delegation.",
            face: "Helvetica",
            at: CGPoint(x: 20, y: 145),
            in: context
        )
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func draw(_ string: String, face: String, at point: CGPoint, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                face as CFString,
                12,
                nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 0.1,
                alpha: 1
            ),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes)
        )
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
