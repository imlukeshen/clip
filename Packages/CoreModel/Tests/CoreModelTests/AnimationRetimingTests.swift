import CoreModel
import Foundation
import Testing

@Suite("Animation follows clip edits")
struct AnimationRetimingTests {
    private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

    /// One 10 s clip whose opacity fades 1 → 0 between 2 s and 8 s, plus a
    /// keyframed zoom at 5–6 s of source.
    private func document(speed: Double = 1) throws -> ProjectDocument {
        var item = TimelineItem(
            id: ItemID(rawValue: "clip"),
            assetID: AssetID(rawValue: "asset"),
            sourceRange: TimeRange(start: .zero, duration: seconds(10 * speed)),
            speed: speed
        )
        item.opacity = Animatable(
            constant: 1,
            keyframes: [Keyframe(time: seconds(2), value: 1), Keyframe(time: seconds(8), value: 0)]
        )
        var zoom = ZoomEffect(
            id: EffectID(rawValue: "zoom"),
            range: TimeRange(start: seconds(5), duration: seconds(2)),
            center: NormalizedPoint(x: 0.5, y: 0.5),
            scale: 2,
            preservesLegacyTiming: false
        )
        zoom.scaleAnimation = Animatable(
            constant: 1,
            keyframes: [Keyframe(time: seconds(5), value: 2), Keyframe(time: seconds(6), value: 1)]
        )
        item.effects = [.zoom(zoom)]
        return try ProjectDocument(
            id: ProjectID(rawValue: "p"),
            name: "P",
            timeline: Timeline(video: [item]),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @Test("Splitting a keyframed clip works and each half plays what it did before")
    func splitRetimesKeyframes() throws {
        var document = try document()
        let original = document.timeline.video[0]
        let inverse = try document.apply(
            TimelineEditPlanner.splitClip(
                in: document, itemID: original.id, at: seconds(4),
                rightItemID: ItemID(rawValue: "right")))
        let left = document.timeline.video[0]
        let right = document.timeline.video[1]

        for local in [0.0, 2, 3, 4] {
            #expect(
                abs(
                    left.opacity.value(at: seconds(local))
                        - original.opacity.value(at: seconds(local))) < 1e-6)
        }
        for local in [0.0, 1, 4, 6] {
            #expect(
                abs(
                    right.opacity.value(at: seconds(local))
                        - original.opacity.value(at: seconds(4 + local)))
                    < 1e-6)
        }
        // The zoom's own keyframes move with its range on the right half.
        guard case .zoom(let zoom) = right.effects.first else {
            Issue.record("zoom missing")
            return
        }
        #expect(zoom.range.start == seconds(1))
        #expect(zoom.scaleAnimation.keyframes.map(\.time) == [seconds(1), seconds(2)])

        _ = try document.apply(inverse)
        #expect(document.timeline.video == [original])
    }

    @Test("A head trim keeps animation on the same picture")
    func headTrimShiftsKeyframes() throws {
        var document = try document()
        let original = document.timeline.video[0]
        _ = try document.apply(
            TimelineEditPlanner.trimClip(
                in: document, itemID: original.id,
                to: TimeRange(start: seconds(1), duration: seconds(9)),
                assetDuration: seconds(10)))
        let trimmed = document.timeline.video[0]
        #expect(trimmed.opacity.keyframes.map(\.time).contains(seconds(1)))
        #expect(
            abs(trimmed.opacity.value(at: seconds(4)) - original.opacity.value(at: seconds(5)))
                < 1e-6)
    }

    @Test("Doubling the speed halves keyframe times instead of rejecting the edit")
    func speedRescalesKeyframes() throws {
        var document = try document()
        _ = try document.apply(TimelineEditPlanner.setSpeed(of: ItemID(rawValue: "clip"), to: 2))
        let fast = document.timeline.video[0]
        #expect(fast.opacity.keyframes.map(\.time) == [seconds(1), seconds(4)])
    }
}
