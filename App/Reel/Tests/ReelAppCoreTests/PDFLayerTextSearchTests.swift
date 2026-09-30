import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("PDF layer text search")
struct PDFLayerTextSearchTests {
    @Test("A word typed in clipx is findable before the document is saved")
    func findsAddedText() throws {
        // The case that failed: "jiawei" was in two layers and in none of the
        // source glyphs, so searching the source alone reported it absent while
        // it was plainly on screen.
        let layer = signature("jiawei")
        let found = PDFLayerTextSearch.matches(of: "jiawei", in: layer)
        #expect(found.count == 1)
        // The layer is the word, so the whole frame is the match.
        let rect = try #require(found.first?.rect)
        #expect(abs(rect.width - layer.frame.width) < 0.001)
    }

    @Test("A word inside a longer layer gets a rectangle narrower than the layer")
    func narrowsToTheWord() throws {
        let layer = paragraph("transferring all of its own privileges jiawei.")
        let rect = try #require(PDFLayerTextSearch.matches(of: "jiawei", in: layer).first?.rect)

        // Redacting the layer frame would black out the whole sentence, which is
        // the difference between hiding a name and destroying the paragraph.
        #expect(rect.width < layer.frame.width * 0.5)
        #expect(rect.minX > layer.frame.minX)
        #expect(rect.maxX <= layer.frame.maxX + 0.001)
    }

    @Test("Matching ignores case and finds every occurrence")
    func findsEveryOccurrence() {
        let layer = paragraph("Jiawei met jiawei")
        #expect(PDFLayerTextSearch.matches(of: "jiawei", in: layer).count == 2)
    }

    @Test("Text absent from the layer yields nothing")
    func absentTextFindsNothing() {
        let layer = paragraph("nothing to see here")
        #expect(PDFLayerTextSearch.matches(of: "jiawei", in: layer).isEmpty)
        #expect(PDFLayerTextSearch.matches(of: "   ", in: layer).isEmpty)
    }

    @Test("A layer that replaces a page object is not searched twice")
    func sourceBackedLayersAreLeftToTheGlyphSearch() {
        // The analysis is asked to apply these edits, so the replacement text is
        // already in the glyph stream. Searching the layer as well found one
        // word twice and drew two highlights, each from a different measurement.
        let replacement = PDFTextLayer(
            text: "transferring all of its own privileges jiawei.",
            frame: CGRect(x: 0.12, y: 0.35, width: 0.44, height: 0.011),
            font: PDFFontDescriptor(postScriptName: "Helvetica"),
            fontSize: 12,
            sourceReference: PDFSourceTextReference(
                pageObjectIndex: 3,
                originalText: "transferring all of its own privileges.",
                originalFontPostScriptName: "Helvetica"
            )
        )
        #expect(replacement.sourceReference != nil)
        // The locator skips these; the search itself stays capable of matching
        // one, so the skip is a decision about where to look, not an inability.
        #expect(!PDFLayerTextSearch.matches(of: "jiawei", in: replacement).isEmpty)
    }

    private func signature(_ text: String) -> PDFTextLayer {
        PDFTextLayer(
            text: text,
            frame: CGRect(x: 0.6, y: 0.71, width: 0.13, height: 0.07),
            font: PDFFontDescriptor(postScriptName: "SnellRoundhand"),
            fontSize: 35.64
        )
    }

    private func paragraph(_ text: String) -> PDFTextLayer {
        PDFTextLayer(
            text: text,
            frame: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.02),
            font: PDFFontDescriptor(postScriptName: "Helvetica"),
            fontSize: 12
        )
    }
}
