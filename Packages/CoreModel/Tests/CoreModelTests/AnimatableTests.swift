import CoreModel
import Foundation
import Testing

@Suite("General keyframes")
struct AnimatableTests {
    @Test("Animatable interpolates and accepts legacy scalars")
    func interpolationAndScalarMigration() throws {
        let animation = Animatable(
            constant: 0.0,
            keyframes: [
                Keyframe(time: .zero, value: 0),
                Keyframe(time: RationalTime(seconds: 2), value: 10),
            ]
        )
        #expect(animation.value(at: RationalTime(seconds: 1)) == 5)

        let migrated = try JSONDecoder().decode(
            Animatable<Double>.self,
            from: Data("0.75".utf8)
        )
        #expect(migrated == Animatable(constant: 0.75))
    }

    @Test("Opacity, transform, gain, blur, and zoom keyframes undo exactly")
    func everyNumericKeyframeUsesThePatchPath() throws {
        let document = try makeDocument()
        let itemID = ItemID(rawValue: "item")
        let trackID = TrackID(rawValue: "v1")
        let blurID = EffectID(rawValue: "blur")
        let zoomID = EffectID(rawValue: "zoom")
        let time = RationalTime(seconds: 1)
        let patches = try [
            TimelineEditPlanner.setOpacityKeyframe(
                in: document, itemID: itemID, at: time, value: 0.4),
            TimelineEditPlanner.setTransformKeyframe(
                in: document,
                itemID: itemID,
                at: time,
                value: Transform2D(scaleX: 0.5, scaleY: 0.5)
            ),
            TimelineEditPlanner.setGainKeyframe(
                in: document, trackID: trackID, at: time, decibels: -9),
            TimelineEditPlanner.setBlurIntensityKeyframe(
                in: document,
                itemID: itemID,
                effectID: blurID,
                at: time,
                value: 24
            ),
            TimelineEditPlanner.setZoomScaleKeyframe(
                in: document,
                itemID: itemID,
                effectID: zoomID,
                at: time,
                value: 2.2
            ),
        ]

        for patch in patches {
            var edited = document
            let inverse = try edited.apply(patch)
            #expect(edited != document)
            _ = try edited.apply(inverse)
            #expect(edited == document)
        }
    }

    @Test("V1 zoom ramps migrate to keyframe data while retaining legacy timing")
    func zoomRampMigration() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "project-v1.json",
                withExtension: nil,
                subdirectory: "Fixtures/golden"
            )
        )
        let document = try ProjectDocument.decodeJSON(Data(contentsOf: url))
        guard case .zoom(let zoom) = try #require(document.timeline.video[0].effects.first) else {
            Issue.record("Expected fixture zoom")
            return
        }
        #expect(zoom.preservesLegacyTiming)
        #expect(zoom.scaleAnimation.keyframes.count == 4)
        #expect(zoom.centerAnimation.keyframes.count == 4)
        #expect(try ProjectDocument.decodeJSON(document.encodedJSON()) == document)
    }

    private func makeDocument() throws -> ProjectDocument {
        let range = TimeRange(start: .zero, duration: RationalTime(seconds: 4))
        let item = TimelineItem(
            id: ItemID(rawValue: "item"),
            assetID: AssetID(rawValue: "asset"),
            sourceRange: range,
            effects: [
                .blur(
                    BlurEffect(
                        id: EffectID(rawValue: "blur"),
                        range: range,
                        regions: [
                            TimedRegion(
                                time: .zero,
                                rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                            )
                        ],
                        mode: .gaussian(radius: 12),
                        isDestructiveOnExport: false
                    )
                ),
                .zoom(
                    ZoomEffect(
                        id: EffectID(rawValue: "zoom"),
                        range: range,
                        center: NormalizedPoint(x: 0.5, y: 0.5),
                        scale: 1.8
                    )
                ),
            ]
        )
        return try ProjectDocument(
            id: ProjectID(rawValue: "keyframes"),
            name: "Keyframes",
            timeline: Timeline(
                videoTracks: [
                    Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item])
                ]
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
