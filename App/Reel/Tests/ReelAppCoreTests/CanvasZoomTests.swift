import Foundation
import Testing

@testable import ReelAppCore

@Suite("Canvas zoom")
struct CanvasZoomTests {
    @Test("Zoom stays inside the usable range")
    func clamping() {
        #expect(CanvasZoom.clamped(0.01) == CanvasZoom.minimum)
        #expect(CanvasZoom.clamped(99) == CanvasZoom.maximum)
        #expect(CanvasZoom.clamped(2) == 2)
        #expect(CanvasZoom.clamped(.nan) == CanvasZoom.fit)
        #expect(CanvasZoom.clamped(.infinity) == CanvasZoom.fit)
    }

    @Test("A pinch moves less than the raw trackpad magnification")
    func pinchIsDamped() {
        let raw = 2.0
        let damped = CanvasZoom.pinched(from: 1, magnification: raw)
        #expect(damped > 1)
        #expect(damped < raw)
    }

    @Test("Pinching is symmetric, so a pinch and its reverse cancel out")
    func pinchIsSymmetric() {
        let inward = CanvasZoom.pinched(from: 1, magnification: 2)
        let outward = CanvasZoom.pinched(from: inward, magnification: 0.5)
        #expect(abs(outward - 1) < 0.0001)
    }

    @Test("A degenerate pinch leaves the zoom alone")
    func pinchIgnoresBadInput() {
        #expect(CanvasZoom.pinched(from: 2, magnification: 0) == 2)
        #expect(CanvasZoom.pinched(from: 2, magnification: -1) == 2)
        #expect(CanvasZoom.pinched(from: 2, magnification: .nan) == 2)
    }

    @Test("Pinching hard in either direction cannot leave the range")
    func pinchRespectsRange() {
        #expect(CanvasZoom.pinched(from: 4, magnification: 40) == CanvasZoom.maximum)
        #expect(CanvasZoom.pinched(from: 0.25, magnification: 0.001) == CanvasZoom.minimum)
    }

    @Test("Steps are multiplicative, so they feel the same at any zoom")
    func stepsAreProportional() {
        #expect(CanvasZoom.zoomedIn(from: 1) == CanvasZoom.step)
        #expect(abs(CanvasZoom.zoomedOut(from: CanvasZoom.step) - 1) < 0.0001)

        let lowRatio = CanvasZoom.zoomedIn(from: 0.5) / 0.5
        let highRatio = CanvasZoom.zoomedIn(from: 2) / 2
        #expect(abs(lowRatio - highRatio) < 0.0001)
    }

    @Test("Stepping stops at the ends of the range")
    func stepsClamp() {
        #expect(CanvasZoom.zoomedIn(from: CanvasZoom.maximum) == CanvasZoom.maximum)
        #expect(CanvasZoom.zoomedOut(from: CanvasZoom.minimum) == CanvasZoom.minimum)
    }

    @Test("The slider puts 100% at its midpoint")
    func sliderIsLogarithmic() {
        let range = CanvasZoom.exponentRange
        let midpoint = (range.lowerBound + range.upperBound) / 2
        #expect(abs(CanvasZoom.value(forExponent: midpoint) - CanvasZoom.fit) < 0.0001)
        #expect(CanvasZoom.value(forExponent: range.lowerBound) == CanvasZoom.minimum)
        #expect(CanvasZoom.value(forExponent: range.upperBound) == CanvasZoom.maximum)
    }

    @Test("Slider positions round-trip through the zoom value")
    func sliderRoundTrips() {
        for value in [0.25, 0.5, 1.0, 2.0, 3.3, 4.0] {
            let restored = CanvasZoom.value(forExponent: CanvasZoom.exponent(for: value))
            #expect(abs(restored - value) < 0.0001)
        }
    }
}
