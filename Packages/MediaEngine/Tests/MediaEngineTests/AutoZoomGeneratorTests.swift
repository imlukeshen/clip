import CoreModel
import Foundation
import Testing

@testable import MediaEngine

@Test func autoZoomClustersClicksAndUsesClipLocalTime() {
    let assetID = AssetID(rawValue: "asset-clicks")
    let item = TimelineItem(
        id: ItemID(rawValue: "item-clicks"),
        assetID: assetID,
        sourceRange: TimeRange(
            start: RationalTime(seconds: 5),
            duration: RationalTime(seconds: 10)
        )
    )
    let track = EventTrack(
        assetID: assetID,
        alignment: .exact(offset: .zero),
        samples: [],
        clicks: [
            click(4.9, x: 0.1, y: 0.1),
            click(6, x: 0.2, y: 0.4),
            click(7, x: 0.6, y: 0.8),
            click(12, x: 0.9, y: 0.1),
        ]
    )

    let zooms = AutoZoomGenerator().zooms(for: track, item: item)

    #expect(zooms.count == 2)
    #expect(zooms[0].range.start == RationalTime(seconds: 0.65))
    #expect(zooms[0].range.end == RationalTime(seconds: 3.7))
    #expect(abs(zooms[0].center.x - 0.4) < 0.000_001)
    #expect(abs(zooms[0].center.y - 0.6) < 0.000_001)
    #expect(zooms[0].source == .derivedFromClicks)
    let firstClickInClip = RationalTime(seconds: 1)
    let reachesTargetAfterClick = zooms[0].range.start + zooms[0].rampIn - firstClickInClip
    #expect(reachesTargetAfterClick <= RationalTime(seconds: 0.2))
    #expect(zooms[1].range.start == RationalTime(seconds: 6.65))
    #expect(zooms[1].range.end == RationalTime(seconds: 8.7))
}

@Test func autoZoomWidensClustersForPathologicalDensity() {
    let assetID = AssetID(rawValue: "asset-dense")
    let item = TimelineItem(
        id: ItemID(rawValue: "item-dense"),
        assetID: assetID,
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 10))
    )
    let track = EventTrack(
        assetID: assetID,
        alignment: .estimated(offset: .zero, confidence: 0.9),
        samples: [],
        clicks: stride(from: 0.25, through: 9.75, by: 0.5).map {
            click($0, x: 0.5, y: 0.5)
        }
    )
    let options = AutoZoomGenerator.Options(
        clusterWindow: 0.1,
        leadIn: 0.1,
        holdOut: 0.1,
        minGap: 0,
        maxPerMinute: 12
    )

    let zooms = AutoZoomGenerator().zooms(for: track, item: item, options: options)

    #expect(zooms.count <= 2)
    #expect(
        zooms.allSatisfy { $0.range.start >= .zero && $0.range.end <= item.sourceRange.duration })
}

@Test func autoZoomRejectsUnavailableOrMismatchedTracks() {
    let item = TimelineItem(
        id: ItemID(rawValue: "item-none"),
        assetID: AssetID(rawValue: "asset-a"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 5))
    )
    let unavailable = EventTrack(
        assetID: item.assetID,
        alignment: .unavailable(reason: "off"),
        samples: [],
        clicks: [click(1, x: 0.5, y: 0.5)]
    )
    let mismatch = EventTrack(
        assetID: AssetID(rawValue: "asset-b"),
        alignment: .exact(offset: .zero),
        samples: [],
        clicks: [click(1, x: 0.5, y: 0.5)]
    )

    #expect(AutoZoomGenerator().zooms(for: unavailable, item: item).isEmpty)
    #expect(AutoZoomGenerator().zooms(for: mismatch, item: item).isEmpty)
}

private func click(_ seconds: Double, x: Double, y: Double) -> ClickEvent {
    ClickEvent(
        time: RationalTime(seconds: seconds),
        point: NormalizedPoint(x: x, y: y),
        button: .left,
        clickCount: 1
    )
}
