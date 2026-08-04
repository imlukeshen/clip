import Foundation
import Testing

@testable import ReelAppCore

@Suite("Inspector layout")
struct InspectorLayoutTests {
    @Test("Widths are held inside the resizable range")
    func clampsToRange() {
        #expect(InspectorLayout.clamped(0) == InspectorLayout.minimumWidth)
        #expect(InspectorLayout.clamped(10_000) == InspectorLayout.maximumWidth)
        #expect(InspectorLayout.clamped(260) == 260)
    }

    @Test("A width that is not a number falls back to the default")
    func rejectsNonFiniteWidths() {
        #expect(InspectorLayout.clamped(.nan) == InspectorLayout.defaultWidth)
        #expect(InspectorLayout.clamped(.infinity) == InspectorLayout.defaultWidth)
    }

    @Test("The default sits inside the range the user can drag to")
    func defaultIsReachable() {
        #expect(InspectorLayout.defaultWidth >= InspectorLayout.minimumWidth)
        #expect(InspectorLayout.defaultWidth <= InspectorLayout.maximumWidth)
    }

    @Test("The minimum keeps editor controls readable")
    func minimumSupportsRichControls() {
        #expect(InspectorLayout.minimumWidth >= 240)
    }

    @Test("A fresh install starts at the default rather than at zero")
    func restoresDefaultWhenUnset() {
        let defaults = makeDefaults()
        #expect(InspectorLayout.restoredWidth(from: defaults) == InspectorLayout.defaultWidth)
    }

    @Test("A dragged width survives a relaunch")
    func roundTripsThroughStorage() {
        let defaults = makeDefaults()
        InspectorLayout.store(320, in: defaults)
        #expect(InspectorLayout.restoredWidth(from: defaults) == 320)
    }

    @Test("A stored width from another build is clamped on the way back in")
    func clampsRestoredWidth() {
        let defaults = makeDefaults()
        defaults.set(2_000, forKey: "reel.inspectorWidth")
        #expect(InspectorLayout.restoredWidth(from: defaults) == InspectorLayout.maximumWidth)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "reel.tests.\(UUID().uuidString)") ?? .standard
    }
}
