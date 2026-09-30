import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("PDF mark hit testing")
struct PDFMarkHitTestTests {
    @Test("A click inside a redaction selects it")
    func redactionIsSelectable() {
        // Redactions had no hit target: the page resolved text and paragraphs
        // and treated everything else as empty canvas, so clicking one
        // deselected and Delete had nothing to remove.
        let redaction = redaction(at: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.02))
        let hit = PDFMarkHitTest.topmost(
            at: CGPoint(x: 0.25, y: 0.51), in: [redaction], rotation: .degrees0)
        #expect(hit?.layerID == redaction.id)
        #expect(hit?.regionIndex == 0)
    }

    @Test("A click outside every mark selects nothing")
    func emptyCanvasSelectsNothing() {
        let redaction = redaction(at: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.02))
        #expect(
            PDFMarkHitTest.topmost(
                at: CGPoint(x: 0.7, y: 0.2), in: [redaction], rotation: .degrees0) == nil)
    }

    @Test("A thin mark is still reachable without pixel-perfect aim")
    func toleranceMakesThinMarksHittable() {
        // A redaction over one line of body text is about 1% of the page tall.
        let thin = redaction(at: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.008))
        let justAbove = CGPoint(x: 0.25, y: 0.5 - PDFMarkHitTest.tolerance / 2)
        #expect(
            PDFMarkHitTest.topmost(at: justAbove, in: [thin], rotation: .degrees0)?.layerID
                == thin.id)
    }

    @Test("The topmost mark wins where they overlap")
    func topmostWins() {
        let rect = CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0.05)
        let under = redaction(at: rect)
        let over = redaction(at: rect)
        // A redaction sits over what it hides, so the click is aimed at the one
        // drawn last rather than at anything beneath it.
        #expect(
            PDFMarkHitTest.topmost(
                at: CGPoint(x: 0.25, y: 0.52), in: [under, over], rotation: .degrees0)?.layerID
                == over.id)
    }

    @Test("Text layers are not marks")
    func textIsNotAMark() {
        let text = PDFLayer.text(
            PDFTextLayer(text: "hello", frame: CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0.05)))
        #expect(PDFMarkHitTest.regions(of: text).isEmpty)
        #expect(
            PDFMarkHitTest.topmost(
                at: CGPoint(x: 0.25, y: 0.52), in: [text], rotation: .degrees0) == nil)
    }

    @Test("Hits follow a rotated page")
    func rotationMovesTheTarget() {
        let mark = redaction(at: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1))
        let upright = CGPoint(x: 0.2, y: 0.25)
        #expect(
            PDFMarkHitTest.topmost(at: upright, in: [mark], rotation: .degrees0)?.layerID
                == mark.id)
        // Quarter-turned, the same stored rect is drawn elsewhere, so the point
        // that used to hit must now miss and the mapped one must hit.
        #expect(PDFMarkHitTest.topmost(at: upright, in: [mark], rotation: .degrees90) == nil)
        let turned = PDFMarkHitTest.displayBounds(
            CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1), rotation: .degrees90)
        #expect(
            PDFMarkHitTest.topmost(
                at: CGPoint(x: turned.midX, y: turned.midY), in: [mark], rotation: .degrees90)?
                .layerID == mark.id)
    }

    @Test("A batch redaction reports which of its regions was clicked")
    func multiRegionLayerReportsTheRegion() throws {
        // Documents redacted before each match became its own layer hold one
        // layer per page carrying every match on it — fifteen regions on a page
        // is normal. Selecting by layer alone made those all-or-nothing.
        let batch = PDFLayer.redaction(
            PDFRedactionLayer(
                regions: (0..<5).map {
                    CGRect(x: 0.1 + Double($0) * 0.15, y: 0.5, width: 0.05, height: 0.01)
                }))

        let third = try #require(
            PDFMarkHitTest.topmost(
                at: CGPoint(x: 0.425, y: 0.505), in: [batch], rotation: .degrees0))
        #expect(third.layerID == batch.id)
        #expect(third.regionIndex == 2)

        let first = try #require(
            PDFMarkHitTest.topmost(
                at: CGPoint(x: 0.125, y: 0.505), in: [batch], rotation: .degrees0))
        #expect(first.regionIndex == 0)
    }

    private func redaction(at rect: CGRect) -> PDFLayer {
        .redaction(PDFRedactionLayer(regions: [rect]))
    }
}
