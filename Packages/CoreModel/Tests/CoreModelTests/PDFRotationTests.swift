import CoreGraphics
import Foundation
import Testing

@testable import CoreModel

@Suite("PDF mark rotation")
struct PDFRotationTests {
    private let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
            && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test(
        "Storing a drawn mark and displaying it again returns the same rect",
        arguments: PDFPageRotation.allCases)
    func roundTrip(rotation: PDFPageRotation) {
        #expect(close(rotation.displayRect(for: rotation.storedRect(fromDisplay: rect)), rect))
        #expect(close(rotation.storedRect(fromDisplay: rotation.displayRect(for: rect)), rect))
    }

    @Test("Version 1 documents move rotated-page marks into unrotated space once")
    func upgradeConvertsRotatedMarks() throws {
        var page = PDFPage(sourcePageIndex: 0, size: PDFPageSize(width: 612, height: 792))
        page.rotation = .degrees90
        page.layers = [
            .redaction(PDFRedactionLayer(regions: [rect])),
            .highlight(PDFHighlightLayer(regions: [rect])),
        ]
        let flat = PDFPage(
            sourcePageIndex: 1,
            size: PDFPageSize(width: 612, height: 792),
            layers: [.redaction(PDFRedactionLayer(regions: [rect]))]
        )
        let legacy = try PDFEditDocument(
            schemaVersion: 1,
            sourceAssetID: AssetID(rawValue: "a"),
            title: "Legacy",
            pages: [page, flat]
        )

        let upgraded = legacy.upgradedToCurrentSchema()

        #expect(upgraded.schemaVersion == PDFEditDocument.currentSchemaVersion)
        guard case .redaction(let redaction) = upgraded.pages[0].layers[0],
            case .highlight(let highlight) = upgraded.pages[0].layers[1],
            case .redaction(let unrotated) = upgraded.pages[1].layers[0]
        else {
            Issue.record("Layer kinds changed")
            return
        }
        // Each mark still displays exactly where version 1 drew it.
        #expect(close(PDFPageRotation.degrees90.displayRect(for: redaction.regions[0]), rect))
        #expect(close(PDFPageRotation.degrees90.displayRect(for: highlight.regions[0]), rect))
        #expect(unrotated.regions[0] == rect)
        #expect(upgraded.upgradedToCurrentSchema() == upgraded)
    }
}
