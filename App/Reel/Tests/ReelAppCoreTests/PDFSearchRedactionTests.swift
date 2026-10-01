import CoreGraphics
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("PDF search respects redactions")
struct PDFSearchRedactionTests {
    @Test("Matches under a redaction are dropped and context near one is withheld")
    func searchHidesRedactedText() throws {
        let redacted = PDFPage(
            sourcePageIndex: 0,
            size: PDFPageSize(width: 612, height: 792),
            layers: [
                .redaction(
                    PDFRedactionLayer(regions: [CGRect(x: 0, y: 0, width: 0.5, height: 0.1)]))
            ]
        )
        let clean = PDFPage(sourcePageIndex: 1, size: PDFPageSize(width: 612, height: 792))
        let document = try PDFEditDocument(
            sourceAssetID: AssetID(rawValue: "pdf"),
            title: "Doc",
            pages: [redacted, clean]
        )
        let matches = [
            PDFTextMatch(
                pageID: redacted.id, rect: CGRect(x: 0.1, y: 0.02, width: 0.1, height: 0.02),
                snippet: "SSN 123"),
            PDFTextMatch(
                pageID: redacted.id, rect: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.02),
                snippet: "near SSN 123"),
            PDFTextMatch(
                pageID: clean.id, rect: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.02),
                snippet: "public text"),
        ]

        let visible = PDFToolExecutor.withoutRedactedText(matches, in: document)

        #expect(visible.count == 2)
        #expect(!visible.contains { $0.snippet.contains("123") })
        #expect(visible.contains { $0.snippet == "public text" })
    }
}
