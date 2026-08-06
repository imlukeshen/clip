import CoreModel

/// The resolved placement for a clip move, including the point that should be
/// shown as the magnetic alignment guide when a snap occurred.
public struct TimelineMoveSnapResult: Sendable, Equatable {
    public var timelineStart: RationalTime
    public var point: SnapPoint?

    public init(timelineStart: RationalTime, point: SnapPoint?) {
        self.timelineStart = timelineStart
        self.point = point
    }
}

/// Resolves magnetic alignment for a moving clip by comparing both clip edges.
public enum TimelineMoveSnapper {
    public static func snap(
        proposedStart: RationalTime,
        duration: RationalTime,
        to points: [SnapPoint],
        threshold: RationalTime,
        excludingIDs: Set<String> = []
    ) -> TimelineMoveSnapResult {
        let leading = SnapEngine.snap(
            proposedStart,
            to: points,
            threshold: threshold,
            excludingIDs: excludingIDs
        )
        let proposedEnd = proposedStart + duration
        let trailing = SnapEngine.snap(
            proposedEnd,
            to: points,
            threshold: threshold,
            excludingIDs: excludingIDs
        )
        let leadingAdjustment = abs((leading.time - proposedStart).seconds)
        let trailingAdjustment = abs((trailing.time - proposedEnd).seconds)

        if leading.point != nil,
            trailing.point == nil || leadingAdjustment <= trailingAdjustment
        {
            return TimelineMoveSnapResult(
                timelineStart: max(leading.time, .zero),
                point: leading.point
            )
        }
        if trailing.point != nil {
            return TimelineMoveSnapResult(
                timelineStart: max(trailing.time - duration, .zero),
                point: trailing.point
            )
        }
        return TimelineMoveSnapResult(timelineStart: max(proposedStart, .zero), point: nil)
    }
}
