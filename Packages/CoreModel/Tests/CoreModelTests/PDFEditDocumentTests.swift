import CoreGraphics
import Foundation
import Testing

@testable import CoreModel

@Suite("PDF document editing")
struct PDFEditDocumentTests {
    @Test("PDF patches preserve exact identity through 1,000 inverse operations")
    func patchInversesRestoreIdentity() throws {
        var document = try fixture()
        var random = Generator(state: 0xC0FFEE)

        for step in 0..<1_000 {
            let patch = makePatch(for: document, step: step, random: &random)
            let before = document
            let inverse = try document.apply(patch)
            var restored = document
            _ = try restored.apply(inverse)
            #expect(restored == before, "Inverse failed at step \(step)")
        }
    }

    @Test("PDF documents and every patch shape round-trip through JSON")
    func codingRoundTrip() throws {
        let document = try fixture()
        let page = try #require(document.pages.first)
        let layer = PDFLayer.text(
            PDFTextLayer(
                text: "Replacement",
                frame: CGRect(x: 0.1, y: 0.15, width: 0.5, height: 0.08)
            )
        )
        let patches: [PDFPatch] = [
            .insertPage(page, atIndex: 0),
            .removePage(page.id),
            .updatePage(page),
            .reorderPage(page.id, to: 1),
            .addLayer(layer, to: page.id, atIndex: 0),
            .removeLayer(layer.id, from: page.id),
            .updateLayer(layer, on: page.id),
            .setOCRText("Recognized text", on: page.id),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(
            try decoder.decode(PDFEditDocument.self, from: encoder.encode(document)) == document)
        for patch in patches {
            #expect(try decoder.decode(PDFPatch.self, from: encoder.encode(patch)) == patch)
        }
    }

    @Test("Subset font descriptors warn only for unseen replacement glyphs")
    func subsetWarnings() {
        let font = PDFFontDescriptor(postScriptName: "ABCDEF+Inter-Regular", isEmbedded: true)
        #expect(font.isSubset)
        #expect(font.warning(for: "Hello", observedCharacters: Set("Hello world")) == nil)
        #expect(
            font.warning(for: "Total €", observedCharacters: Set("Total USD"))?.contains("€")
                == true)
        #expect(!PDFFontDescriptor(postScriptName: "Inter-Regular").isSubset)
    }

    @Test("Invalid PDF mutations are transactional")
    func invalidMutationIsTransactional() throws {
        var document = try fixture()
        let before = document
        let invalid = PDFLayer.highlight(
            PDFHighlightLayer(regions: [CGRect(x: 0.9, y: 0.9, width: 0.2, height: 0.2)])
        )
        #expect(throws: PDFDocumentError.self) {
            _ = try document.apply(.addLayer(invalid, to: document.pages[0].id, atIndex: 0))
        }
        #expect(document == before)
    }

    private func fixture() throws -> PDFEditDocument {
        try PDFEditDocument(
            sourceAssetID: AssetID(rawValue: "source-pdf"),
            title: "Release Notes",
            pages: (0..<3).map {
                PDFPage(
                    sourcePageIndex: $0,
                    size: PDFPageSize(width: 612, height: 792)
                )
            }
        )
    }

    private func makePatch(
        for document: PDFEditDocument,
        step: Int,
        random: inout Generator
    ) -> PDFPatch {
        let pageIndex = random.index(document.pages.count)
        let page = document.pages[pageIndex]
        switch random.next() % 7 {
        case 0:
            var updated = page
            updated.rotation = updated.rotation.rotatedClockwise()
            return .updatePage(updated)
        case 1:
            return .setOCRText("OCR \(step)", on: page.id)
        case 2:
            let layer = PDFLayer.highlight(
                PDFHighlightLayer(
                    regions: [CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)]
                )
            )
            return .addLayer(layer, to: page.id, atIndex: page.layers.count)
        case 3 where !page.layers.isEmpty:
            return .removeLayer(page.layers[random.index(page.layers.count)].id, from: page.id)
        case 4:
            return .reorderPage(page.id, to: random.index(document.pages.count))
        case 5 where document.pages.count < 8:
            let blank = PDFPage(
                sourcePageIndex: nil,
                size: PDFPageSize(width: 612, height: 792)
            )
            return .insertPage(blank, atIndex: random.index(document.pages.count + 1))
        case 6 where document.pages.count > 1:
            return .removePage(page.id)
        default:
            var updated = page
            updated.ocrText = nil
            return .updatePage(updated)
        }
    }
}

private struct Generator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }

    mutating func index(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}
