import CoreImage
import CoreModel
import Foundation
import Testing

@testable import MediaEngine

@Suite("Caption overlay")
struct CaptionOverlayTests {
    private let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)

    private func caption(_ text: String, from start: Double, to end: Double) -> CaptionSegment {
        CaptionSegment(
            id: text,
            range: TimeRange(
                start: RationalTime(seconds: start),
                duration: RationalTime(seconds: end - start)
            ),
            text: text
        )
    }

    @Test("The caption on screen is the one whose range holds the time")
    func activeCaption() {
        let captions = [caption("one", from: 0, to: 2), caption("two", from: 2, to: 4)]
        #expect(CaptionOverlay.active(captions, at: RationalTime(seconds: 1))?.text == "one")
        #expect(CaptionOverlay.active(captions, at: RationalTime(seconds: 2))?.text == "two")
        #expect(CaptionOverlay.active(captions, at: RationalTime(seconds: 5)) == nil)
    }

    @Test("A caption is drawn centred near the bottom of the frame and stays inside it")
    func captionPlacement() throws {
        let image = try #require(CaptionOverlay.image(for: "Ship it today", in: bounds))
        let extent = image.extent
        #expect(bounds.contains(extent))
        #expect(abs(extent.midX - bounds.midX) < 1)
        // Core Image's origin is the bottom: the box sits in the lower fifth.
        #expect(extent.minY < bounds.height * 0.2)
        #expect(extent.minY > 0)
    }

    @Test("Long captions wrap within the frame instead of running off it")
    func longCaptionWraps() throws {
        let text = String(repeating: "a long spoken sentence ", count: 12)
        let image = try #require(CaptionOverlay.image(for: text, in: bounds))
        #expect(image.extent.width <= bounds.width * 0.8 + 1)
        #expect(bounds.contains(image.extent))
    }

    @Test("Blank captions draw nothing")
    func blankCaption() {
        #expect(CaptionOverlay.image(for: "   \n", in: bounds) == nil)
    }
}
