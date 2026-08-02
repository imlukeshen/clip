import CoreModel
import Foundation
import Testing

@Suite("Precision timeline editing")
struct TimelinePrecisionEditingTests {
    @Test("Ripple, roll, slip, and slide preserve I3 across 1,000 edits")
    func precisionEditsRestoreExactIdentity() throws {
        for sequence in 0..<250 {
            let delta = RationalTime(seconds: Double((sequence % 17) - 8) / 10)

            try assertInverse(
                document: makeDocument(sequence),
                patch: { document in
                    try TimelineEditPlanner.rippleDelete(
                        in: document,
                        itemID: ItemID(rawValue: "middle-\(sequence)")
                    )
                }
            )
            try assertInverse(
                document: makeDocument(sequence),
                patch: { document in
                    try TimelineEditPlanner.rollEdit(
                        in: document,
                        leftItemID: ItemID(rawValue: "left-\(sequence)"),
                        by: delta,
                        assetDurations: durations(sequence)
                    )
                }
            )
            try assertInverse(
                document: makeDocument(sequence),
                patch: { document in
                    try TimelineEditPlanner.slipClip(
                        in: document,
                        itemID: ItemID(rawValue: "middle-\(sequence)"),
                        by: delta,
                        assetDuration: RationalTime(seconds: 12)
                    )
                }
            )
            try assertInverse(
                document: makeDocument(sequence),
                patch: { document in
                    try TimelineEditPlanner.slideClip(
                        in: document,
                        itemID: ItemID(rawValue: "middle-\(sequence)"),
                        by: delta,
                        assetDurations: durations(sequence)
                    )
                }
            )
        }
    }

    @Test("Snapping chooses the nearest deterministic editor point")
    func snappingUsesPlayheadEdgesMarkersAndClicks() throws {
        let document = try makeDocument(1)
        let points = SnapEngine.points(
            in: document.timeline,
            playhead: RationalTime(seconds: 7.5),
            clickTimes: [RationalTime(seconds: 4.9)]
        )
        let result = SnapEngine.snap(
            RationalTime(seconds: 4.94),
            to: points,
            threshold: RationalTime(seconds: 0.1)
        )

        #expect(result.time == RationalTime(seconds: 4.9))
        #expect(result.point?.kind == .click)
        #expect(
            SnapEngine.snap(
                RationalTime(seconds: 8.2),
                to: points,
                threshold: RationalTime(seconds: 0.1)
            ).point == nil
        )
    }

    @Test("Overwrite splits a spanning clip and returns an exact inverse")
    func overwriteSplitsSpanningClip() throws {
        let source = TimelineItem(
            id: ItemID(rawValue: "source"),
            assetID: AssetID(rawValue: "source-asset"),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 10))
        )
        let inserted = TimelineItem(
            id: ItemID(rawValue: "inserted"),
            assetID: AssetID(rawValue: "inserted-asset"),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 2))
        )
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "overwrite"),
            name: "Overwrite",
            timeline: Timeline(video: [source]),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let trackID = try #require(document.timeline.videoTracks.first?.id)
        let patch = try TimelineEditPlanner.overwrite(
            in: document,
            item: inserted,
            on: trackID,
            at: RationalTime(seconds: 4),
            splitRightItemID: ItemID(rawValue: "right")
        )
        var edited = document
        let inverse = try edited.apply(patch)

        #expect(edited.timeline.video.map(\.timelineStart) == [
            .zero, RationalTime(seconds: 4), RationalTime(seconds: 6),
        ])
        #expect(edited.timeline.video.map(\.timelineDuration) == [
            RationalTime(seconds: 4), RationalTime(seconds: 2), RationalTime(seconds: 4),
        ])
        _ = try edited.apply(inverse)
        #expect(edited == document)
    }

    @Test("Cross dissolve and audio fades are exact undoable attributes")
    func transitionAndFadesUndoExactly() throws {
        let document = try makeDocument(42)
        var edited = document
        let dissolve = try TimelineEditPlanner.crossDissolve(
            in: edited,
            leftItemID: ItemID(rawValue: "left-42"),
            duration: RationalTime(seconds: 0.5)
        )
        let dissolveInverse = try edited.apply(dissolve)
        #expect(edited.timeline.video[0].videoFade.fadeOut == RationalTime(seconds: 0.5))
        #expect(edited.timeline.video[1].videoFade.fadeIn == RationalTime(seconds: 0.5))
        _ = try edited.apply(dissolveInverse)
        #expect(edited == document)

        let fade = try TimelineEditPlanner.setAudioFade(
            in: edited,
            itemID: ItemID(rawValue: "middle-42"),
            fadeIn: RationalTime(seconds: 0.25),
            fadeOut: RationalTime(seconds: 0.5)
        )
        let fadeInverse = try edited.apply(fade)
        #expect(edited.timeline.video[1].audioFade.fadeIn == RationalTime(seconds: 0.25))
        _ = try edited.apply(fadeInverse)
        #expect(edited == document)
    }

    private func assertInverse(
        document: ProjectDocument,
        patch: (ProjectDocument) throws -> GraphPatch
    ) throws {
        var edited = document
        let inverse = try edited.apply(try patch(document))
        try edited.validate()
        _ = try edited.apply(inverse)
        #expect(edited == document)
    }

    private func makeDocument(_ sequence: Int) throws -> ProjectDocument {
        let duration = RationalTime(seconds: 5)
        func item(_ name: String) -> TimelineItem {
            TimelineItem(
                id: ItemID(rawValue: "\(name)-\(sequence)"),
                assetID: AssetID(rawValue: "\(name)-asset-\(sequence)"),
                sourceRange: TimeRange(
                    start: RationalTime(seconds: 2),
                    duration: duration
                )
            )
        }
        return try ProjectDocument(
            id: ProjectID(rawValue: "precision-\(sequence)"),
            name: "Precision \(sequence)",
            timeline: Timeline(video: [item("left"), item("middle"), item("right")]),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func durations(_ sequence: Int) -> [AssetID: RationalTime] {
        Dictionary(
            uniqueKeysWithValues: ["left", "middle", "right"].map {
                (AssetID(rawValue: "\($0)-asset-\(sequence)"), RationalTime(seconds: 12))
            }
        )
    }
}
