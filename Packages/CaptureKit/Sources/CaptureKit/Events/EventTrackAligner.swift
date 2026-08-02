import CoreGraphics
import CoreModel
import Foundation

/// Pure conversion from captured system events into an asset-relative event track.
public struct EventTrackAligner: Sendable {
    public init() {}

    public func align(
        assetDuration: RationalTime,
        fileCreated: Date,
        fileModified: Date,
        windows: [CaptureWindow],
        events: [RawEvent],
        displayBounds: CGRect,
        assetID: AssetID = AssetID(rawValue: "unassociated-event-track")
    ) -> EventTrack {
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            return unavailable(assetID, "recorded display bounds are invalid")
        }

        let exact =
            windows
            .filter {
                abs($0.duration - assetDuration.seconds) <= 1.5
                    && abs($0.endedAt.timeIntervalSince(fileModified)) <= 10
            }
            .min {
                abs($0.duration - assetDuration.seconds)
                    < abs($1.duration - assetDuration.seconds)
            }

        if let exact {
            let selected = events.filter {
                $0.machHostTime >= exact.start && $0.machHostTime <= exact.end
            }
            return makeTrack(
                assetID: assetID,
                alignment: .exact(
                    offset: RationalTime(seconds: HostClock.seconds(from: exact.start))),
                events: selected,
                assetDuration: assetDuration,
                displayBounds: displayBounds,
                relativeTime: {
                    HostClock.seconds(from: exact.start, to: $0.machHostTime)
                }
            )
        }

        let measuredDuration = fileModified.timeIntervalSince(fileCreated)
        let tolerance = assetDuration.seconds * 0.2
        if tolerance > 0, abs(measuredDuration - assetDuration.seconds) <= tolerance {
            let confidence = max(0, 1 - abs(measuredDuration - assetDuration.seconds) / tolerance)
            let selected = events.filter {
                $0.wallTime >= fileCreated
                    && $0.wallTime <= fileCreated.addingTimeInterval(assetDuration.seconds)
            }
            return makeTrack(
                assetID: assetID,
                alignment: .estimated(
                    offset: RationalTime(seconds: fileCreated.timeIntervalSinceReferenceDate),
                    confidence: confidence
                ),
                events: selected,
                assetDuration: assetDuration,
                displayBounds: displayBounds,
                relativeTime: { $0.wallTime.timeIntervalSince(fileCreated) }
            )
        }

        return unavailable(assetID, "no matching capture window")
    }

    private func makeTrack(
        assetID: AssetID,
        alignment: Alignment,
        events: [RawEvent],
        assetDuration: RationalTime,
        displayBounds: CGRect,
        relativeTime: (RawEvent) -> TimeInterval
    ) -> EventTrack {
        let timedEvents = events.compactMap { event -> (RawEvent, TimeInterval)? in
            let time = relativeTime(event)
            guard time >= 0, time <= assetDuration.seconds else { return nil }
            return (event, time)
        }
        let positional = timedEvents.map(\.0).filter { $0.kind == .mouseMoved || $0.isClick }
        let outsideCount = positional.count {
            !displayBounds.contains($0.location)
        }
        if !positional.isEmpty, Double(outsideCount) / Double(positional.count) > 0.2 {
            return unavailable(assetID, "cursor left the recorded display for too long")
        }

        let samples = timedEvents.compactMap { event, time -> CursorSample? in
            guard event.kind == .mouseMoved else { return nil }
            return CursorSample(
                time: RationalTime(seconds: time),
                point: normalize(event.location, in: displayBounds)
            )
        }
        let clicks = timedEvents.compactMap { event, time -> ClickEvent? in
            guard event.isClick else { return nil }
            return ClickEvent(
                time: RationalTime(seconds: time),
                point: normalize(event.location, in: displayBounds),
                button: event.kind == .leftMouseDown ? .left : .right,
                clickCount: max(event.clickCount, 1)
            )
        }
        return EventTrack(
            assetID: assetID,
            alignment: alignment,
            samples: samples,
            clicks: clicks
        )
    }

    private func normalize(_ point: CGPoint, in bounds: CGRect) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max((point.x - bounds.minX) / bounds.width, 0), 1),
            y: min(max((point.y - bounds.minY) / bounds.height, 0), 1)
        )
    }

    private func unavailable(_ assetID: AssetID, _ reason: String) -> EventTrack {
        EventTrack(
            assetID: assetID,
            alignment: .unavailable(reason: reason),
            samples: [],
            clicks: []
        )
    }
}
