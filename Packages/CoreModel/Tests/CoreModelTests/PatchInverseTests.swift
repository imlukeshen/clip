import CoreModel
import Foundation
import Testing

@Test func lockedTrackRejectsGraphMutationTransactionally() throws {
    let item = TimelineItem(
        id: ItemID(rawValue: "locked-item"),
        assetID: AssetID(rawValue: "locked-asset"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 1))
    )
    var document = try ProjectDocument(
        id: ProjectID(rawValue: "locked-project"),
        name: "Locked",
        timeline: Timeline(
            videoTracks: [
                Track(
                    id: TrackID(rawValue: "v1"),
                    name: "V1",
                    items: [item],
                    isLocked: true
                )
            ]
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let original = document

    #expect(throws: ModelError.trackLocked(TrackID(rawValue: "v1"))) {
        try document.apply(
            GraphPatch(ops: [.setSpeed(item.id, 2)], label: "Speed", origin: .user)
        )
    }
    #expect(document == original)
}

@Test func patchAndInverseRestoreIdentityAcrossOneThousandRandomSequences() throws {
    var random = DeterministicRandom(seed: 0x5EED_CAFE)

    for sequence in 0..<1_000 {
        let original = try makeDocument(sequence: sequence, random: &random)
        var planned = original
        var operations: [GraphOp] = []

        for step in 0..<random.int(in: 3...14) {
            let operation = randomOperation(
                sequence: sequence,
                step: step,
                document: planned,
                random: &random
            )
            var next = planned
            _ = try next.apply(
                GraphPatch(ops: [operation], label: "Plan", origin: .automation(rule: "test"))
            )
            planned = next
            operations.append(operation)
        }

        var actual = original
        let inverse = try actual.apply(
            GraphPatch(ops: operations, label: "Random sequence", origin: .user)
        )
        #expect(actual == planned, "Sequence \(sequence) did not match its planned state")

        _ = try actual.apply(inverse)
        #expect(actual == original, "Sequence \(sequence) did not restore exact identity")
    }
}

@Test func invalidPatchIsTransactional() throws {
    var random = DeterministicRandom(seed: 12)
    var document = try makeDocument(sequence: 0, random: &random)
    let original = document
    let itemID = try #require(document.timeline.video.first?.id)
    let patch = GraphPatch(
        ops: [
            .rename("This must roll back"),
            .setEnabled(itemID, false),
            .setSpeed(itemID, 10),
        ],
        label: "Invalid transaction",
        origin: .user
    )

    do {
        _ = try document.apply(patch)
        Issue.record("Expected invalid speed to reject the patch")
    } catch let error as ModelError {
        #expect(error == .invalidSpeed(10))
    }
    #expect(document == original)
}

@Test func replacingTrackListsIsExactlyUndoable() throws {
    var random = DeterministicRandom(seed: 19)
    var document = try makeDocument(sequence: 19, random: &random)
    let original = document
    let overlay = Track(
        id: TrackID(rawValue: "v2"),
        name: "V2",
        items: [
            TimelineItem(
                id: ItemID(rawValue: "overlay"),
                assetID: AssetID(rawValue: "overlay-asset"),
                sourceRange: TimeRange(
                    start: .zero,
                    duration: RationalTime(seconds: 1)
                )
            )
        ],
        isLocked: true
    )
    let audio = Track(
        id: TrackID(rawValue: "a2"),
        name: "A2",
        items: [
            TimelineItem(
                id: ItemID(rawValue: "detached-audio"),
                assetID: AssetID(rawValue: "overlay-asset"),
                sourceRange: TimeRange(
                    start: .zero,
                    duration: RationalTime(seconds: 1)
                )
            )
        ]
    )

    let inverse = try document.apply(
        GraphPatch(
            ops: [
                .setVideoTracks(document.timeline.videoTracks + [overlay]),
                .setAudioTracks(document.timeline.audioTracks + [audio]),
            ],
            label: "Add Tracks",
            origin: .user
        )
    )

    #expect(document.timeline.videoTracks.last == overlay)
    #expect(document.timeline.audioTracks.last == audio)
    _ = try document.apply(inverse)
    #expect(document == original)
}

@Test func secondaryVideoAndAudioItemsSupportEveryIDBasedMutation() throws {
    var document = try makeMultiTrackDocument()
    let original = document
    let overlayID = ItemID(rawValue: "overlay")
    let detachedAudioID = ItemID(rawValue: "detached-audio")
    let effectID = EffectID(rawValue: "overlay-effect")
    let effect = Effect.zoom(
        ZoomEffect(
            id: effectID,
            range: TimeRange(start: .zero, duration: RationalTime(seconds: 2)),
            center: NormalizedPoint(x: 0.5, y: 0.5),
            scale: 1.5
        )
    )
    let updatedEffect = Effect.zoom(
        ZoomEffect(
            id: effectID,
            range: TimeRange(start: .zero, duration: RationalTime(seconds: 2)),
            center: NormalizedPoint(x: 0.25, y: 0.75),
            scale: 2
        )
    )

    let undoAdd = try document.apply(
        GraphPatch(ops: [.addEffect(overlayID, effect)], label: "Add", origin: .user)
    )
    #expect(document.item(overlayID)?.effects == [effect])
    let undoUpdate = try document.apply(
        GraphPatch(ops: [.updateEffect(overlayID, updatedEffect)], label: "Update", origin: .user)
    )
    #expect(document.item(overlayID)?.effects == [updatedEffect])
    let undoRemove = try document.apply(
        GraphPatch(ops: [.removeEffect(overlayID, effectID)], label: "Remove", origin: .user)
    )
    #expect(document.item(overlayID)?.effects.isEmpty == true)

    _ = try document.apply(undoRemove)
    _ = try document.apply(undoUpdate)
    _ = try document.apply(undoAdd)
    #expect(document == original)

    let inverse = try document.apply(
        GraphPatch(
            ops: [
                .setSourceRange(
                    overlayID,
                    TimeRange(
                        start: RationalTime(seconds: 0.25),
                        duration: RationalTime(seconds: 1.5)
                    )
                ),
                .setSpeed(overlayID, 2),
                .setEnabled(overlayID, false),
                .setSourceRange(
                    detachedAudioID,
                    TimeRange(
                        start: RationalTime(seconds: 0.5),
                        duration: RationalTime(seconds: 1)
                    )
                ),
                .setSpeed(detachedAudioID, 0.5),
                .setEnabled(detachedAudioID, false),
            ],
            label: "Edit secondary tracks",
            origin: .user
        )
    )

    let overlay = try #require(document.item(overlayID))
    let detachedAudio = try #require(document.item(detachedAudioID))
    #expect(overlay.sourceRange.start == RationalTime(seconds: 0.25))
    #expect(overlay.sourceRange.duration == RationalTime(seconds: 1.5))
    #expect(overlay.speed == 2)
    #expect(!overlay.isEnabled)
    #expect(detachedAudio.sourceRange.start == RationalTime(seconds: 0.5))
    #expect(detachedAudio.sourceRange.duration == RationalTime(seconds: 1))
    #expect(detachedAudio.speed == 0.5)
    #expect(!detachedAudio.isEnabled)
    #expect(document.timeline.videoTracks[0] == original.timeline.videoTracks[0])
    #expect(document.timeline.audioTracks[0] == original.timeline.audioTracks[0])

    _ = try document.apply(inverse)
    #expect(document == original)
}

@Test func secondaryTrackRemovalAndMoveAreExactlyUndoable() throws {
    var document = try makeMultiTrackDocument()
    let original = document

    let removalInverse = try document.apply(
        GraphPatch(
            ops: [
                .removeItem(ItemID(rawValue: "overlay")),
                .removeItem(ItemID(rawValue: "detached-audio")),
            ],
            label: "Remove secondary media",
            origin: .user
        )
    )
    #expect(document.timeline.videoTracks[1].items.isEmpty)
    #expect(document.timeline.audioTracks[1].items.isEmpty)
    #expect(document.timeline.videoTracks[0] == original.timeline.videoTracks[0])
    #expect(document.timeline.audioTracks[0] == original.timeline.audioTracks[0])

    _ = try document.apply(removalInverse)
    #expect(document == original)

    let videoA = TimelineItem(
        id: ItemID(rawValue: "video-a"),
        assetID: AssetID(rawValue: "video-a-asset"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 1)),
        timelineStart: RationalTime(seconds: 3)
    )
    let videoB = TimelineItem(
        id: ItemID(rawValue: "video-b"),
        assetID: AssetID(rawValue: "video-b-asset"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 2)),
        timelineStart: RationalTime(seconds: 5)
    )
    let audioA = TimelineItem(
        id: ItemID(rawValue: "audio-a"),
        assetID: AssetID(rawValue: "audio-a-asset"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 3)),
        timelineStart: RationalTime(seconds: 2)
    )
    let audioB = TimelineItem(
        id: ItemID(rawValue: "audio-b"),
        assetID: AssetID(rawValue: "audio-b-asset"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 1)),
        timelineStart: RationalTime(seconds: 6)
    )
    document.timeline.videoTracks[1].items = [videoA, videoB]
    document.timeline.audioTracks[1].items = [audioA, audioB]
    let beforeMove = document

    let moveInverse = try document.apply(
        GraphPatch(
            ops: [
                .moveItem(videoA.id, toIndex: 1),
                .moveItem(audioB.id, toIndex: 0),
            ],
            label: "Reorder secondary media",
            origin: .user
        )
    )
    #expect(document.timeline.videoTracks[1].items.map(\.id) == [videoB.id, videoA.id])
    #expect(document.timeline.audioTracks[1].items.map(\.id) == [audioB.id, audioA.id])
    #expect(
        document.timeline.videoTracks[1].items.map(\.timelineStart) == [
            .zero, RationalTime(seconds: 2),
        ])
    #expect(
        document.timeline.audioTracks[1].items.map(\.timelineStart) == [
            .zero, RationalTime(seconds: 1),
        ])
    #expect(document.timeline.videoTracks[0] == beforeMove.timeline.videoTracks[0])
    #expect(document.timeline.audioTracks[0] == beforeMove.timeline.audioTracks[0])

    _ = try document.apply(moveInverse)
    #expect(document == beforeMove)
}

@Test func removingAndUndoingSoleCustomizedPrimaryItemsRestoresTrackMetadata() throws {
    let range = TimeRange(start: .zero, duration: RationalTime(seconds: 2))
    let videoItem = TimelineItem(
        id: ItemID(rawValue: "custom-video"),
        assetID: AssetID(rawValue: "custom-video-asset"),
        sourceRange: range
    )
    let audioItem = TimelineItem(
        id: ItemID(rawValue: "custom-audio"),
        assetID: AssetID(rawValue: "custom-audio-asset"),
        sourceRange: range
    )
    let customVideoTrack = Track(
        id: TrackID(rawValue: "v1"),
        name: "Hero Camera",
        items: [videoItem],
        isEnabled: false,
        isMuted: true,
        isSolo: true,
        gain: -3
    )
    let customAudioTrack = Track(
        id: TrackID(rawValue: "a1"),
        name: "Dialogue",
        items: [audioItem],
        isEnabled: false,
        isMuted: true,
        isSolo: true,
        gain: -6
    )
    var document = try ProjectDocument(
        id: ProjectID(rawValue: "custom-primary-project"),
        name: "Custom primary tracks",
        timeline: Timeline(
            videoTracks: [customVideoTrack],
            audioTracks: [customAudioTrack]
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let original = document

    let inverse = try document.apply(
        GraphPatch(
            ops: [
                .removeItem(videoItem.id),
                .removeItem(audioItem.id),
            ],
            label: "Remove customized primaries",
            origin: .user
        )
    )
    #expect(document.timeline.videoTracks.isEmpty)
    #expect(document.timeline.audioTracks.isEmpty)

    _ = try document.apply(inverse)
    #expect(document == original)
    #expect(document.timeline.videoTracks == [customVideoTrack])
    #expect(document.timeline.audioTracks == [customAudioTrack])
}

@Test func primaryTimingMutationsRippleLocallyAndUndoGappedTracksExactly() throws {
    func item(_ id: String, duration: Double, start: Double) -> TimelineItem {
        TimelineItem(
            id: ItemID(rawValue: id),
            assetID: AssetID(rawValue: "asset-\(id)"),
            sourceRange: TimeRange(
                start: .zero,
                duration: RationalTime(seconds: duration)
            ),
            timelineStart: RationalTime(seconds: start)
        )
    }
    let videoItems = [
        item("video-first", duration: 2, start: 2),
        item("video-middle", duration: 2, start: 6),
        item("video-last", duration: 1, start: 10),
    ]
    let audioItems = [
        item("audio-first", duration: 2, start: 2),
        item("audio-middle", duration: 2, start: 6),
        item("audio-last", duration: 1, start: 10),
    ]
    var document = try ProjectDocument(
        id: ProjectID(rawValue: "gapped-primary-project"),
        name: "Gapped primaries",
        timeline: Timeline(
            videoTracks: [
                Track(id: TrackID(rawValue: "v1"), name: "V1", items: videoItems)
            ],
            audioTracks: [
                Track(id: TrackID(rawValue: "a1"), name: "A1", items: audioItems)
            ]
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let original = document

    let videoInsert = item("video-insert", duration: 1, start: 50)
    let audioInsert = item("audio-insert", duration: 1, start: 50)
    let insertInverse = try document.apply(
        GraphPatch(
            ops: [
                .insertItem(videoInsert, track: .video, index: 1),
                .insertItem(audioInsert, track: .audio, index: 1),
            ],
            label: "Insert into gaps",
            origin: .user
        )
    )
    #expect(
        document.timeline.video.map(\.timelineStart) == [
            RationalTime(seconds: 2),
            RationalTime(seconds: 6),
            RationalTime(seconds: 7),
            RationalTime(seconds: 11),
        ])
    #expect(
        document.timeline.audio.map(\.timelineStart)
            == document.timeline.video.map(\.timelineStart)
    )
    _ = try document.apply(insertInverse)
    #expect(document == original)

    let removeInverse = try document.apply(
        GraphPatch(
            ops: [
                .removeItem(ItemID(rawValue: "video-middle")),
                .removeItem(ItemID(rawValue: "audio-middle")),
            ],
            label: "Remove from gaps",
            origin: .user
        )
    )
    #expect(
        document.timeline.video.map(\.timelineStart) == [
            RationalTime(seconds: 2), RationalTime(seconds: 8),
        ])
    #expect(
        document.timeline.audio.map(\.timelineStart)
            == document.timeline.video.map(\.timelineStart)
    )
    _ = try document.apply(removeInverse)
    #expect(document == original)

    let rangeInverse = try document.apply(
        GraphPatch(
            ops: [
                .setSourceRange(
                    ItemID(rawValue: "video-middle"),
                    TimeRange(start: .zero, duration: RationalTime(seconds: 3))
                ),
                .setSourceRange(
                    ItemID(rawValue: "audio-middle"),
                    TimeRange(start: .zero, duration: RationalTime(seconds: 3))
                ),
            ],
            label: "Grow clips in gaps",
            origin: .user
        )
    )
    #expect(
        document.timeline.video.map(\.timelineStart) == [
            RationalTime(seconds: 2),
            RationalTime(seconds: 6),
            RationalTime(seconds: 11),
        ])
    #expect(
        document.timeline.audio.map(\.timelineStart)
            == document.timeline.video.map(\.timelineStart)
    )
    _ = try document.apply(rangeInverse)
    #expect(document == original)

    let speedInverse = try document.apply(
        GraphPatch(
            ops: [
                .setSpeed(ItemID(rawValue: "video-middle"), 2),
                .setSpeed(ItemID(rawValue: "audio-middle"), 2),
            ],
            label: "Speed clips in gaps",
            origin: .user
        )
    )
    #expect(
        document.timeline.video.map(\.timelineStart) == [
            RationalTime(seconds: 2),
            RationalTime(seconds: 6),
            RationalTime(seconds: 9),
        ])
    #expect(
        document.timeline.audio.map(\.timelineStart)
            == document.timeline.video.map(\.timelineStart)
    )
    _ = try document.apply(speedInverse)
    #expect(document == original)
}

@Test func lockedSecondaryTrackRejectsItemMutationTransactionally() throws {
    var document = try makeMultiTrackDocument(secondaryVideoLocked: true)
    let original = document

    #expect(throws: ModelError.trackLocked(TrackID(rawValue: "v2"))) {
        try document.apply(
            GraphPatch(
                ops: [.setSpeed(ItemID(rawValue: "overlay"), 2)],
                label: "Locked overlay",
                origin: .user
            )
        )
    }
    #expect(document == original)
}

@Test func projectDurationIncludesEveryVideoAndAudioTrack() throws {
    let video = TimelineItem(
        id: ItemID(rawValue: "short-video"),
        assetID: AssetID(rawValue: "short-video-asset"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 2))
    )
    let overlay = TimelineItem(
        id: ItemID(rawValue: "late-overlay"),
        assetID: AssetID(rawValue: "late-overlay-asset"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 1)),
        timelineStart: RationalTime(seconds: 4)
    )
    let audio = TimelineItem(
        id: ItemID(rawValue: "long-audio"),
        assetID: AssetID(rawValue: "long-audio-asset"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 4)),
        timelineStart: RationalTime(seconds: 3)
    )
    let document = try ProjectDocument(
        id: ProjectID(rawValue: "duration-project"),
        name: "Duration",
        timeline: Timeline(
            videoTracks: [
                Track(id: TrackID(rawValue: "v1"), name: "V1", items: [video]),
                Track(id: TrackID(rawValue: "v2"), name: "V2", items: [overlay]),
            ],
            audioTracks: [
                Track(id: TrackID(rawValue: "a1"), name: "A1", items: [audio])
            ]
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let audioOnly = try ProjectDocument(
        id: ProjectID(rawValue: "audio-only-project"),
        name: "Audio only",
        timeline: Timeline(
            audioTracks: [
                Track(id: TrackID(rawValue: "a1"), name: "A1", items: [audio])
            ]
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )

    #expect(document.duration == RationalTime(seconds: 7))
    #expect(audioOnly.duration == RationalTime(seconds: 7))
}

private func makeDocument(
    sequence: Int,
    random: inout DeterministicRandom
) throws -> ProjectDocument {
    let video = (0..<random.int(in: 1...4)).map { index in
        makeItem(
            id: "video-\(sequence)-\(index)",
            durationTicks: Int64(random.int(in: 90_000...900_000))
        )
    }
    let audio = (0..<random.int(in: 0...2)).map { index in
        makeItem(
            id: "audio-\(sequence)-\(index)",
            durationTicks: Int64(random.int(in: 90_000...900_000))
        )
    }
    return try ProjectDocument(
        id: ProjectID(rawValue: "project-\(sequence)"),
        name: "Project \(sequence)",
        timeline: Timeline(video: video, audio: audio),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeMultiTrackDocument(
    secondaryVideoLocked: Bool = false
) throws -> ProjectDocument {
    let range = TimeRange(start: .zero, duration: RationalTime(seconds: 2))
    func item(_ id: String, start: Double = 0) -> TimelineItem {
        TimelineItem(
            id: ItemID(rawValue: id),
            assetID: AssetID(rawValue: "asset-\(id)"),
            sourceRange: range,
            timelineStart: RationalTime(seconds: start)
        )
    }
    return try ProjectDocument(
        id: ProjectID(rawValue: "multi-track-project"),
        name: "Multi-track",
        timeline: Timeline(
            videoTracks: [
                Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item("primary")]),
                Track(
                    id: TrackID(rawValue: "v2"),
                    name: "V2",
                    items: [item("overlay", start: 3)],
                    isLocked: secondaryVideoLocked
                ),
            ],
            audioTracks: [
                Track(id: TrackID(rawValue: "a1"), name: "A1", items: [item("primary-audio")]),
                Track(
                    id: TrackID(rawValue: "a2"),
                    name: "A2",
                    items: [item("detached-audio", start: 4)]
                ),
            ]
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
}

private func makeItem(id: String, durationTicks: Int64) -> TimelineItem {
    TimelineItem(
        id: ItemID(rawValue: id),
        assetID: AssetID(rawValue: "asset-\(id)"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(value: durationTicks))
    )
}

private func randomOperation(
    sequence: Int,
    step: Int,
    document: ProjectDocument,
    random: inout DeterministicRandom
) -> GraphOp {
    let choice = random.int(in: 0...11)
    switch choice {
    case 0:
        let track: TrackKind = random.bool() ? .video : .audio
        let count = track == .video ? document.timeline.video.count : document.timeline.audio.count
        let item = makeItem(
            id: "inserted-\(sequence)-\(step)",
            durationTicks: Int64(random.int(in: 45_000...540_000))
        )
        return .insertItem(item, track: track, index: random.int(in: 0...count))

    case 1:
        let allItems = document.timeline.video + document.timeline.audio
        if allItems.count > 1 {
            return .removeItem(allItems[random.int(in: 0...(allItems.count - 1))].id)
        }
        return .rename("Project \(sequence), step \(step)")

    case 2:
        let candidateTracks = [document.timeline.video, document.timeline.audio].filter {
            !$0.isEmpty
        }
        guard !candidateTracks.isEmpty else {
            return .rename("Empty \(step)")
        }
        let track = candidateTracks[random.int(in: 0...(candidateTracks.count - 1))]
        let item = track[random.int(in: 0...(track.count - 1))]
        return .moveItem(item.id, toIndex: random.int(in: 0...(track.count - 1)))

    case 3:
        guard let item = randomItem(in: document, random: &random) else {
            return .rename("No item \(step)")
        }
        let start = RationalTime(value: Int64(random.int(in: 0...90_000)))
        return .setSourceRange(
            item.id,
            TimeRange(start: start, duration: item.sourceRange.duration)
        )

    case 4:
        guard let item = randomItem(in: document, random: &random) else {
            return .rename("No speed \(step)")
        }
        let speeds = [0.25, 0.5, 1, 2, 4]
        return .setSpeed(item.id, speeds[random.int(in: 0...(speeds.count - 1))])

    case 5:
        guard let item = randomItem(in: document, random: &random) else {
            return .rename("No toggle \(step)")
        }
        return .setEnabled(item.id, !item.isEnabled)

    case 6:
        guard let item = randomItem(in: document, random: &random),
            item.sourceRange.duration > .zero
        else {
            return .rename("No effect target \(step)")
        }
        let effect = Effect.zoom(
            ZoomEffect(
                id: EffectID(rawValue: "effect-\(sequence)-\(step)"),
                range: TimeRange(start: .zero, duration: item.sourceRange.duration),
                center: NormalizedPoint(x: random.unitDouble(), y: random.unitDouble()),
                scale: Double(random.int(in: 10...40)) / 10
            )
        )
        return .addEffect(item.id, effect)

    case 7:
        let itemsWithEffects = (document.timeline.video + document.timeline.audio).filter {
            !$0.effects.isEmpty
        }
        guard !itemsWithEffects.isEmpty else {
            return .rename("No removable effect \(step)")
        }
        let item = itemsWithEffects[random.int(in: 0...(itemsWithEffects.count - 1))]
        let effect = item.effects[random.int(in: 0...(item.effects.count - 1))]
        return .removeEffect(item.id, effect.id)

    case 8:
        let itemsWithEffects = (document.timeline.video + document.timeline.audio).filter {
            !$0.effects.isEmpty
        }
        guard !itemsWithEffects.isEmpty else {
            return .rename("No update effect \(step)")
        }
        let item = itemsWithEffects[random.int(in: 0...(itemsWithEffects.count - 1))]
        let effect = item.effects[random.int(in: 0...(item.effects.count - 1))]
        return .updateEffect(item.id, updated(effect, random: &random))

    case 9:
        let caption = CaptionSegment(
            id: "caption-\(sequence)-\(step)",
            range: TimeRange(start: .zero, duration: RationalTime(seconds: 1)),
            text: "Sequence \(sequence)"
        )
        return .setCaptions(random.bool() ? [caption] : [])

    case 10:
        return .setCanvas(
            CanvasSpec(
                width: random.bool() ? 1_920 : 1_280,
                height: random.bool() ? 1_080 : 720,
                frameRate: random.bool() ? .fps30 : .fps60,
                colorSpace: random.bool() ? .sRGB : .displayP3,
                background: .black
            )
        )

    default:
        return .rename("Project \(sequence), step \(step)")
    }
}

private func randomItem(
    in document: ProjectDocument,
    random: inout DeterministicRandom
) -> TimelineItem? {
    let items = document.timeline.video + document.timeline.audio
    guard !items.isEmpty else { return nil }
    return items[random.int(in: 0...(items.count - 1))]
}

private func updated(
    _ effect: Effect,
    random: inout DeterministicRandom
) -> Effect {
    switch effect {
    case .zoom(var zoom):
        zoom.scale = Double(random.int(in: 10...40)) / 10
        return .zoom(zoom)
    case .crop(var crop):
        crop.rect.x = random.unitDouble() / 2
        return .crop(crop)
    case .background(var background):
        background.padding = random.unitDouble() / 4
        return .background(background)
    case .blur(var blur):
        blur.isDestructiveOnExport.toggle()
        return .blur(blur)
    case .cursor(var cursor):
        cursor.opacity = random.unitDouble()
        return .cursor(cursor)
    case .text(var text):
        text.text += "."
        return .text(text)
    case .unknown:
        return effect
    }
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }

    mutating func bool() -> Bool {
        next().isMultiple(of: 2)
    }

    mutating func unitDouble() -> Double {
        Double(next() % 10_001) / 10_000
    }
}
