import CoreModel
import MediaEngine
import Testing

@Suite("Zoom evaluation")
struct ZoomEvaluatorTests {
    @Test("Ramp interpolation and later-effect precedence are deterministic")
    func rampAndPrecedence() {
        let first = ZoomEffect(
            id: EffectID(rawValue: "first"),
            range: TimeRange(start: .zero, duration: RationalTime(seconds: 4)),
            center: NormalizedPoint(x: 0.6, y: 0.5),
            scale: 2,
            rampIn: RationalTime(seconds: 1),
            rampOut: RationalTime(seconds: 1)
        )
        let later = ZoomEffect(
            id: EffectID(rawValue: "later"),
            range: TimeRange(
                start: RationalTime(seconds: 1),
                duration: RationalTime(seconds: 2)
            ),
            center: NormalizedPoint(x: 0.5, y: 0.5),
            scale: 3,
            rampIn: RationalTime(seconds: 1),
            rampOut: RationalTime(seconds: 1)
        )

        #expect(ZoomEvaluator.state(at: .zero, effects: [first]).scale == 1)
        #expect(ZoomEvaluator.state(at: RationalTime(seconds: 0.5), effects: [first]).scale == 1.5)
        #expect(
            ZoomEvaluator.state(at: RationalTime(seconds: 2), effects: [first, later]).scale == 3)
    }

    @Test("Edge clamping prevents a zoom from exposing the canvas")
    func edgeClamp() {
        let result = ZoomEvaluator.clampCentre(
            NormalizedPoint(x: 0, y: 1),
            scale: 2
        )
        #expect(result == NormalizedPoint(x: 0.25, y: 0.75))
    }
}
