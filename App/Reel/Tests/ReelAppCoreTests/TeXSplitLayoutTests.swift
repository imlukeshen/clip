import Foundation
import Testing

@testable import ReelAppCore

@Suite("LaTeX split layout")
struct TeXSplitLayoutTests {
    @Test("Fractions are held inside the draggable range")
    func clampsToRange() {
        #expect(TeXSplitLayout.clamped(0) == TeXSplitLayout.minimumPreviewFraction)
        #expect(TeXSplitLayout.clamped(1) == TeXSplitLayout.maximumPreviewFraction)
        #expect(TeXSplitLayout.clamped(0.5) == 0.5)
        #expect(TeXSplitLayout.clamped(.nan) == TeXSplitLayout.defaultPreviewFraction)
    }

    @Test("A wide window opens with the source slightly wider than the page")
    func defaultSplitFavoursSource() {
        let width = TeXSplitLayout.previewWidth(
            fraction: TeXSplitLayout.defaultPreviewFraction,
            availableWidth: 1_500
        )
        #expect(abs(width - 615) < 0.001)
        #expect(1_500 - width > width)
    }

    @Test("A narrow surface keeps both panes at their minimums")
    func narrowSurfaceHonoursMinimums() {
        let available = TeXSplitLayout.minimumSourceWidth + TeXSplitLayout.minimumPreviewWidth + 20
        let small = TeXSplitLayout.previewWidth(fraction: 0.2, availableWidth: available)
        let large = TeXSplitLayout.previewWidth(fraction: 0.8, availableWidth: available)
        #expect(small == TeXSplitLayout.minimumPreviewWidth)
        #expect(available - large == TeXSplitLayout.minimumSourceWidth)
    }

    @Test("When both minimums cannot fit, the source keeps its width")
    func sourceWinsWhenCramped() {
        let width = TeXSplitLayout.previewWidth(fraction: 0.5, availableWidth: 400)
        #expect(400 - width == TeXSplitLayout.minimumSourceWidth)
    }

    @Test("A dragged width converts back to the same fraction")
    func widthRoundTripsThroughFraction() {
        let fraction = TeXSplitLayout.fraction(previewWidth: 600, availableWidth: 1_200)
        #expect(fraction == 0.5)
        #expect(TeXSplitLayout.previewWidth(fraction: fraction, availableWidth: 1_200) == 600)
    }

    @Test("A fresh install starts at the default split")
    func restoresDefaultWhenUnset() {
        let defaults = makeDefaults()
        #expect(
            TeXSplitLayout.restoredFraction(from: defaults) == TeXSplitLayout.defaultPreviewFraction
        )
    }

    @Test("A dragged split survives a relaunch")
    func roundTripsThroughStorage() {
        let defaults = makeDefaults()
        TeXSplitLayout.store(0.55, in: defaults)
        #expect(TeXSplitLayout.restoredFraction(from: defaults) == 0.55)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "reel.tests.\(UUID().uuidString)") ?? .standard
    }
}
