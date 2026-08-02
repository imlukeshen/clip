import CoreModel
import Foundation

/// Deterministically derives clip-local zooms from an aligned click track.
public struct AutoZoomGenerator: Sendable {
    public struct Options: Codable, Sendable, Equatable {
        public var clusterWindow: TimeInterval
        public var leadIn: TimeInterval
        public var holdOut: TimeInterval
        public var scale: Double
        public var minGap: TimeInterval
        public var maxPerMinute: Int

        public init(
            clusterWindow: TimeInterval = 2.5,
            leadIn: TimeInterval = 0.35,
            holdOut: TimeInterval = 1.7,
            scale: Double = 1.85,
            minGap: TimeInterval = 0.6,
            maxPerMinute: Int = 12
        ) {
            self.clusterWindow = clusterWindow
            self.leadIn = leadIn
            self.holdOut = holdOut
            self.scale = scale
            self.minGap = minGap
            self.maxPerMinute = maxPerMinute
        }
    }

    public init() {}

    public func zooms(
        for track: EventTrack,
        item: TimelineItem,
        options: Options = Options()
    ) -> [ZoomEffect] {
        guard track.assetID == item.assetID else { return [] }
        if case .unavailable = track.alignment { return [] }

        let clicks = track.clicks
            .filter { $0.time >= item.sourceRange.start && $0.time < item.sourceRange.end }
            .sorted { $0.time < $1.time }
        guard !clicks.isEmpty else { return [] }

        let itemMinutes = max(item.timelineDuration.seconds / 60, 1 / 60)
        let limit = max(1, Int((itemMinutes * Double(max(options.maxPerMinute, 1))).rounded(.down)))
        var window = max(options.clusterWindow, 0.01)
        var clusters = cluster(clicks, within: window)
        let maximumWindow = max(item.sourceRange.duration.seconds, window)
        while clusters.count > limit, window < maximumWindow {
            window = min(maximumWindow, window * 1.5)
            clusters = cluster(clicks, within: window)
        }

        let pending = clusters.map { cluster -> PendingZoom in
            let localStart = cluster[0].time - item.sourceRange.start
            let localEnd = cluster[cluster.count - 1].time - item.sourceRange.start
            return PendingZoom(
                start: max(localStart - RationalTime(seconds: max(options.leadIn, 0)), .zero),
                end: min(
                    localEnd + RationalTime(seconds: max(options.holdOut, 0)),
                    item.sourceRange.duration
                ),
                clicks: cluster
            )
        }
        let merged = merge(pending, minimumGap: max(options.minGap, 0))

        return merged.enumerated().compactMap { index, zoom in
            guard zoom.end > zoom.start else { return nil }
            let center = centroid(of: zoom.clicks)
            return ZoomEffect(
                id: EffectID(
                    rawValue:
                        "derived-clicks-\(item.id.rawValue)-\(index)-\(zoom.start.value)-\(zoom.end.value)"
                ),
                range: TimeRange(start: zoom.start, duration: zoom.end - zoom.start),
                center: center,
                scale: max(options.scale, 1),
                source: .derivedFromClicks
            )
        }
    }

    private func cluster(_ clicks: [ClickEvent], within window: TimeInterval) -> [[ClickEvent]] {
        var result: [[ClickEvent]] = []
        for click in clicks {
            if let last = result.last?.last,
                click.time.seconds - last.time.seconds <= window
            {
                result[result.count - 1].append(click)
            } else {
                result.append([click])
            }
        }
        return result
    }

    private func merge(_ zooms: [PendingZoom], minimumGap: TimeInterval) -> [PendingZoom] {
        var result: [PendingZoom] = []
        let gap = RationalTime(seconds: minimumGap)
        for zoom in zooms {
            if let last = result.last, zoom.start - last.end < gap {
                result[result.count - 1] = PendingZoom(
                    start: last.start,
                    end: max(last.end, zoom.end),
                    clicks: last.clicks + zoom.clicks
                )
            } else {
                result.append(zoom)
            }
        }
        return result
    }

    private func centroid(of clicks: [ClickEvent]) -> NormalizedPoint {
        let count = Double(clicks.count)
        return NormalizedPoint(
            x: clicks.reduce(0) { $0 + $1.point.x } / count,
            y: clicks.reduce(0) { $0 + $1.point.y } / count
        )
    }
}

private struct PendingZoom {
    var start: RationalTime
    var end: RationalTime
    var clicks: [ClickEvent]
}
