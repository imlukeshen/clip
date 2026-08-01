import CoreModel
import Foundation
import Testing

@Test func everyKnownEffectRoundTripsThroughProjectJSON() throws {
    let duration = RationalTime(seconds: 3)
    let range = TimeRange(start: .zero, duration: duration)
    let effects: [Effect] = [
        .zoom(
            ZoomEffect(
                id: EffectID(rawValue: "zoom"),
                range: range,
                center: NormalizedPoint(x: 0.4, y: 0.6),
                scale: 1.8,
                source: .derivedFromClicks
            )
        ),
        .crop(
            CropEffect(
                id: EffectID(rawValue: "crop"),
                range: range,
                rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            )
        ),
        .background(
            BackgroundEffect(
                id: EffectID(rawValue: "background"),
                range: range,
                padding: 0.08,
                cornerRadius: 16,
                style: .solid(RGBA(r: 0.1, g: 0.2, b: 0.3, a: 1)),
                shadow: ShadowSpec(
                    color: RGBA(r: 0, g: 0, b: 0, a: 0.5),
                    radius: 12,
                    offsetX: 0,
                    offsetY: 4
                )
            )
        ),
        .blur(
            BlurEffect(
                id: EffectID(rawValue: "blur"),
                range: range,
                regions: [
                    TimedRegion(
                        time: .zero,
                        rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2)
                    )
                ],
                mode: .gaussian(radius: 18),
                isDestructiveOnExport: true
            )
        ),
        .cursor(
            CursorEffect(
                id: EffectID(rawValue: "cursor"),
                range: range,
                scale: 1.4,
                opacity: 0.9
            )
        ),
        .text(
            TextEffect(
                id: EffectID(rawValue: "text"),
                range: range,
                text: "Hello",
                position: NormalizedPoint(x: 0.5, y: 0.8),
                fontSize: 42,
                color: RGBA(r: 1, g: 1, b: 1, a: 1)
            )
        ),
    ]
    let item = TimelineItem(
        id: ItemID(rawValue: "item"),
        assetID: AssetID(rawValue: "asset"),
        sourceRange: range,
        effects: effects
    )
    let document = try ProjectDocument(
        id: ProjectID(rawValue: "project"),
        name: "Effects",
        timeline: Timeline(video: [item]),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(try ProjectDocument.decodeJSON(document.encodedJSON()) == document)
}

@Test func patchAndEventContractsAreCodable() throws {
    let range = TimeRange(start: .zero, duration: RationalTime(seconds: 1))
    let item = TimelineItem(
        id: ItemID(rawValue: "item"),
        assetID: AssetID(rawValue: "asset"),
        sourceRange: range
    )
    let effect = Effect.cursor(
        CursorEffect(
            id: EffectID(rawValue: "effect"),
            range: range,
            scale: 1.5
        )
    )
    let patch = GraphPatch(
        ops: [
            .insertItem(item, track: .video, index: 0),
            .moveItem(item.id, toIndex: 0),
            .setSourceRange(item.id, range),
            .setSpeed(item.id, 2),
            .setEnabled(item.id, false),
            .addEffect(item.id, effect),
            .updateEffect(item.id, effect),
            .removeEffect(item.id, effect.id),
            .setCaptions([]),
            .setCanvas(.fullHD),
            .rename("Renamed"),
            .removeItem(item.id),
        ],
        label: "Round trip",
        origin: .assistant(turnID: "turn-1")
    )
    let eventTrack = EventTrack(
        assetID: item.assetID,
        alignment: .estimated(offset: RationalTime(seconds: 0.1), confidence: 0.82),
        samples: [CursorSample(time: .zero, point: NormalizedPoint(x: 0.2, y: 0.3))],
        clicks: [
            ClickEvent(
                time: RationalTime(seconds: 0.5),
                point: NormalizedPoint(x: 0.4, y: 0.6),
                button: .left,
                clickCount: 1
            )
        ]
    )

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    #expect(try decoder.decode(GraphPatch.self, from: encoder.encode(patch)) == patch)
    #expect(try decoder.decode(EventTrack.self, from: encoder.encode(eventTrack)) == eventTrack)
}
