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

@Suite("Edits away from 1x stay gapless and non-overlapping")
struct SpeedRoundingTests {
    private func document(speeds: [Double]) throws -> ProjectDocument {
        var start = RationalTime.zero
        let items = speeds.enumerated().map { index, speed in
            let item = TimelineItem(
                id: ItemID(rawValue: "clip-\(index)"),
                assetID: AssetID(rawValue: "asset"),
                sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 10)),
                timelineStart: start,
                speed: speed
            )
            start = item.timelineEnd
            return item
        }
        return try ProjectDocument(
            id: ProjectID(rawValue: "p"),
            name: "P",
            timeline: Timeline(video: items),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @Test(
        "Splitting a half-speed clip at odd ticks always succeeds",
        arguments: [3, 3003, 90_001, 449_999])
    func splitAtOddTick(offsetTicks: Int64) throws {
        var document = try document(speeds: [0.5, 1])
        let original = document.timeline.video[0]
        _ = try document.apply(
            TimelineEditPlanner.splitClip(
                in: document, itemID: original.id,
                at: RationalTime(seconds: 5) + RationalTime(value: offsetTicks),
                rightItemID: ItemID(rawValue: "right")))
        let video = document.timeline.video
        #expect(video[0].timelineEnd == video[1].timelineStart)
        #expect(video[1].timelineEnd <= original.timelineEnd)
        #expect(video[2].timelineStart >= video[1].timelineEnd)
    }

    @Test("Rolling a cut between 1.5x clips by an odd tick count stays gapless")
    func rollAtOddTicks() throws {
        var document = try document(speeds: [1.5, 1.5])
        let left = document.timeline.video[0]
        _ = try document.apply(
            TimelineEditPlanner.rollEdit(
                in: document, leftItemID: left.id, by: RationalTime(value: 7),
                assetDurations: [AssetID(rawValue: "asset"): RationalTime(seconds: 20)]))
        let video = document.timeline.video
        #expect(video[0].timelineEnd == video[1].timelineStart)
    }
}

@Suite("Small timeline guards")
struct TimelineGuardTests {
    @Test("A zoom shorter than its ramps is still a valid document", arguments: [0.84, 0.3])
    func shortZoomIsValid(seconds: Double) throws {
        let zoom = ZoomEffect(
            id: EffectID(rawValue: "z"),
            range: TimeRange(start: .zero, duration: RationalTime(seconds: seconds)),
            center: NormalizedPoint(x: 0.5, y: 0.5),
            scale: 2
        )
        let times = zoom.scaleAnimation.keyframes.map(\.time)
        #expect(Set(times).count == times.count)
        #expect(times.allSatisfy { $0 >= .zero && $0 <= RationalTime(seconds: seconds) })
    }

    @Test("A trim outside the asset is refused rather than leaving an empty clip")
    func emptyTrimIsRefused() throws {
        let item = TimelineItem(
            id: ItemID(rawValue: "clip"),
            assetID: AssetID(rawValue: "asset"),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 10))
        )
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "p"), name: "P", timeline: Timeline(video: [item]),
            createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1))
        #expect(throws: ModelError.self) {
            _ = try TimelineEditPlanner.trimClip(
                in: document, itemID: item.id,
                to: TimeRange(start: RationalTime(seconds: 20), duration: RationalTime(seconds: 5)),
                assetDuration: RationalTime(seconds: 10))
        }
    }
}
