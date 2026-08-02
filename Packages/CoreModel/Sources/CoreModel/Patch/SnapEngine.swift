import Foundation

public enum SnapKind: String, Codable, Sendable, Equatable, CaseIterable {
    case playhead
    case clipEdge
    case marker
    case click
}

public struct SnapPoint: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var time: RationalTime
    public var kind: SnapKind

    public init(id: String, time: RationalTime, kind: SnapKind) {
        self.id = id
        self.time = time
        self.kind = kind
    }
}

public struct SnapResult: Sendable, Equatable {
    public var time: RationalTime
    public var point: SnapPoint?

    public init(time: RationalTime, point: SnapPoint?) {
        self.time = time
        self.point = point
    }
}

/// Deterministic snapping shared by timeline gestures and commands.
public enum SnapEngine {
    public static func points(
        in timeline: Timeline,
        playhead: RationalTime? = nil,
        clickTimes: [RationalTime] = []
    ) -> [SnapPoint] {
        var points: [SnapPoint] = []
        if let playhead {
            points.append(SnapPoint(id: "playhead", time: playhead, kind: .playhead))
        }
        for track in timeline.videoTracks + timeline.audioTracks {
            for item in track.items {
                points.append(
                    SnapPoint(
                        id: "\(item.id.rawValue)-start",
                        time: item.timelineStart,
                        kind: .clipEdge
                    )
                )
                points.append(
                    SnapPoint(
                        id: "\(item.id.rawValue)-end",
                        time: item.timelineEnd,
                        kind: .clipEdge
                    )
                )
            }
        }
        points.append(
            contentsOf: timeline.markers.map {
                SnapPoint(id: $0.id.rawValue, time: $0.time, kind: .marker)
            }
        )
        points.append(
            contentsOf: clickTimes.enumerated().map {
                SnapPoint(id: "click-\($0.offset)", time: $0.element, kind: .click)
            }
        )
        return points
    }

    public static func snap(
        _ proposed: RationalTime,
        to points: [SnapPoint],
        threshold: RationalTime,
        excludingIDs: Set<String> = []
    ) -> SnapResult {
        guard threshold >= .zero else { return SnapResult(time: proposed, point: nil) }
        var candidates: [(point: SnapPoint, distance: Double)] = []
        for point in points where !excludingIDs.contains(point.id) {
            let distance = abs((point.time - proposed).seconds)
            if distance <= threshold.seconds {
                candidates.append((point, distance))
            }
        }
        candidates.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.point.time != $1.point.time { return $0.point.time < $1.point.time }
            return $0.point.id < $1.point.id
        }
        let candidate = candidates.first?.point
        return SnapResult(time: candidate?.time ?? proposed, point: candidate)
    }
}
