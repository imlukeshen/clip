import CoreModel
import Foundation
import Testing

@Suite("Timeline edit planning")
struct TimelineEditPlannerTests {
    @Test("Splitting slices clip-local effects and undo restores exact identity")
    func splitAndUndo() throws {
        let original = try document(speed: 1)
        let itemID = try #require(original.timeline.video.first?.id)
        let patch = try TimelineEditPlanner.splitClip(
            in: original,
            itemID: itemID,
            at: RationalTime(seconds: 3),
            rightItemID: ItemID(rawValue: "right")
        )

        var edited = original
        let inverse = try edited.apply(patch)

        #expect(edited.timeline.video.count == 2)
        #expect(edited.duration == original.duration)
        let left = edited.timeline.video[0]
        let right = edited.timeline.video[1]
        #expect(left.sourceRange.duration == RationalTime(seconds: 3))
        #expect(right.sourceRange.start == RationalTime(seconds: 3))
        #expect(
            left.effects.map(\.range) == [
                TimeRange(start: RationalTime(seconds: 1), duration: RationalTime(seconds: 1)),
                TimeRange(start: RationalTime(seconds: 2), duration: RationalTime(seconds: 1)),
            ])
        #expect(
            right.effects.map(\.range) == [
                TimeRange(start: .zero, duration: RationalTime(seconds: 1)),
                TimeRange(start: RationalTime(seconds: 1), duration: RationalTime(seconds: 1)),
            ])

        _ = try edited.apply(inverse)
        #expect(edited == original)
    }

    @Test("Split time is converted through clip speed")
    func splitAtSpeed() throws {
        let original = try document(speed: 2)
        let itemID = try #require(original.timeline.video.first?.id)
        let patch = try TimelineEditPlanner.splitClip(
            in: original,
            itemID: itemID,
            at: RationalTime(seconds: 1.5),
            rightItemID: ItemID(rawValue: "right")
        )
        var edited = original
        _ = try edited.apply(patch)

        #expect(edited.timeline.video[0].sourceRange.duration == RationalTime(seconds: 3))
        #expect(edited.duration == original.duration)
    }

    @Test("Splits within four tenths of a boundary are rejected")
    func boundaryGuard() throws {
        let original = try document(speed: 1)
        let itemID = try #require(original.timeline.video.first?.id)

        #expect(throws: ModelError.self) {
            try TimelineEditPlanner.splitClip(
                in: original,
                itemID: itemID,
                at: RationalTime(seconds: 0.2),
                rightItemID: ItemID(rawValue: "right")
            )
        }
    }

    @Test("Trimming shifts retained effects and undo restores identity")
    func trimAndUndo() throws {
        let original = try document(speed: 1)
        let itemID = try #require(original.timeline.video.first?.id)
        let patch = try TimelineEditPlanner.trimClip(
            in: original,
            itemID: itemID,
            to: TimeRange(
                start: RationalTime(seconds: 2),
                duration: RationalTime(seconds: 3)
            ),
            assetDuration: RationalTime(seconds: 6)
        )
        var edited = original
        let inverse = try edited.apply(patch)

        #expect(
            edited.timeline.video[0].effects.map(\.range) == [
                TimeRange(start: .zero, duration: RationalTime(seconds: 2)),
                TimeRange(start: RationalTime(seconds: 2), duration: RationalTime(seconds: 1)),
            ])
        _ = try edited.apply(inverse)
        #expect(edited == original)
    }

    private func document(speed: Double) throws -> ProjectDocument {
        let effects: [Effect] = [
            .zoom(
                ZoomEffect(
                    id: EffectID(rawValue: "left"),
                    range: TimeRange(
                        start: RationalTime(seconds: 1),
                        duration: RationalTime(seconds: 1)
                    ),
                    center: NormalizedPoint(x: 0.5, y: 0.5),
                    scale: 2
                )
            ),
            .zoom(
                ZoomEffect(
                    id: EffectID(rawValue: "crossing"),
                    range: TimeRange(
                        start: RationalTime(seconds: 2),
                        duration: RationalTime(seconds: 2)
                    ),
                    center: NormalizedPoint(x: 0.5, y: 0.5),
                    scale: 2
                )
            ),
            .zoom(
                ZoomEffect(
                    id: EffectID(rawValue: "right"),
                    range: TimeRange(
                        start: RationalTime(seconds: 4),
                        duration: RationalTime(seconds: 1)
                    ),
                    center: NormalizedPoint(x: 0.5, y: 0.5),
                    scale: 2
                )
            ),
        ]
        let item = TimelineItem(
            id: ItemID(rawValue: "clip"),
            assetID: AssetID(rawValue: "asset"),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 6)),
            speed: speed,
            effects: effects
        )
        return try ProjectDocument(
            id: ProjectID(rawValue: "project"),
            name: "Demo",
            timeline: Timeline(video: [item]),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
