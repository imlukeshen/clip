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
