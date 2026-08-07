import Testing

@testable import ReelAppCore

@Suite("Timeline viewport")
struct TimelineViewportTests {
    @Test("Fit mode is exactly the visible viewport")
    func fitMode() {
        #expect(TimelineViewport.contentWidth(viewportWidth: 900, zoom: 1) == 900)
    }

    @Test("Zoom expands the timeline and respects its limits")
    func zoomLimits() {
        #expect(TimelineViewport.contentWidth(viewportWidth: 800, zoom: 2.5) == 2_000)
        #expect(TimelineViewport.clampedZoom(0.2) == 1)
        #expect(TimelineViewport.clampedZoom(50) == 12)
        #expect(TimelineViewport.zooming(2, by: 1.5) == 3)
        #expect(TimelineViewport.zooming(2, by: .nan) == 2)
    }

    @Test("Editing horizon leaves useful future-time drop space")
    func editingHorizon() {
        #expect(TimelineViewport.editingDuration(projectDuration: 0) == 10)
        #expect(TimelineViewport.editingDuration(projectDuration: 8) == 18)
        #expect(TimelineViewport.editingDuration(projectDuration: 60) == 75)
        #expect(TimelineViewport.editingDuration(projectDuration: .infinity) == 10)
    }

    @Test("Growing projects expand the canvas without changing the established scale")
    func stableScaleWhileProjectGrows() {
        let scale = TimelineViewport.pointsPerSecond(
            viewportWidth: 546,
            zoom: 1,
            referenceDuration: 20
        )
        let expandedWidth = TimelineViewport.stableContentWidth(
            viewportWidth: 546,
            zoom: 1,
            pointsPerSecond: scale,
            requiredDuration: 30
        )

        #expect(scale == 25)
        #expect(expandedWidth == 796)
        #expect((expandedWidth - TimelineViewport.leadingInset) / 30 == scale)
    }

    @Test("Buttons use finer steps near fit and faster steps when zoomed in")
    func steppedZoom() {
        #expect(TimelineViewport.stepping(1, direction: 1) == 1.25)
        #expect(TimelineViewport.stepping(3, direction: 1) == 3.5)
        #expect(TimelineViewport.stepping(7, direction: -1) == 6)
    }
}
