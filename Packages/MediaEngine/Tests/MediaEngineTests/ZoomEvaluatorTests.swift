import CoreModel
import Foundation
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

    @Test("Legacy zoom JSON migrates without changing evaluated frames")
    func legacyZoomMigrationPreservesVisuals() throws {
        let json = Data(
            """
            {"type":"zoom","id":"legacy","range":{"start":{"value":0,"timescale":90000},"duration":{"value":270000,"timescale":90000}},"center":{"x":0.4,"y":0.6},"scale":2,"rampIn":{"value":90000,"timescale":90000},"rampOut":{"value":90000,"timescale":90000},"easing":"smoothstep","source":"manual"}
            """.utf8
        )
        guard case .zoom(let migrated) = try JSONDecoder().decode(Effect.self, from: json) else {
            Issue.record("Expected zoom")
            return
        }
        #expect(migrated.preservesLegacyTiming)
        #expect(!migrated.scaleAnimation.keyframes.isEmpty)

        for seconds in [0.0, 0.25, 0.75, 1.5, 2.25, 2.75, 2.999] {
            let time = RationalTime(seconds: seconds)
            let state = ZoomEvaluator.state(at: time, effects: [migrated])
            let rampIn = min(max(seconds, 0), 1)
            let rampOut = min(max(3 - seconds, 0), 1)
            let raw = min(rampIn, rampOut)
            let progress = raw * raw * (3 - 2 * raw)
            #expect(abs(state.scale - (1 + progress)) < 0.000_001)
            #expect(abs(state.center.x - (0.5 - 0.1 * progress)) < 0.000_001)
            #expect(abs(state.center.y - (0.5 + 0.1 * progress)) < 0.000_001)
        }

        let roundTripped = try JSONDecoder().decode(
            Effect.self,
            from: JSONEncoder().encode(Effect.zoom(migrated))
        )
        #expect(roundTripped == .zoom(migrated))
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
