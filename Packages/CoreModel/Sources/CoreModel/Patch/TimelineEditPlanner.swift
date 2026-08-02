import Foundation

/// Produces validated, undoable graph patches for timeline gestures.
public enum TimelineEditPlanner {
    public static func splitClip(
        in document: ProjectDocument,
        itemID: ItemID,
        at timelineTime: RationalTime,
        rightItemID: ItemID,
        minimumBoundaryDistance: RationalTime = RationalTime(seconds: 0.4)
    ) throws -> GraphPatch {
        guard let index = document.timeline.video.firstIndex(where: { $0.id == itemID }),
            let itemStart = document.timelineStart(of: itemID)
        else {
            throw ModelError.itemNotFound(itemID)
        }
        let item = document.timeline.video[index]
        let localTimelineTime = timelineTime - itemStart
        guard localTimelineTime >= minimumBoundaryDistance,
            item.timelineDuration - localTimelineTime >= minimumBoundaryDistance
        else {
            throw ModelError.splitTooCloseToBoundary(
                itemID,
                minimumDistance: minimumBoundaryDistance
            )
        }

        let sourceOffset = localTimelineTime.scaled(by: item.speed)
        let leftRange = TimeRange(
            start: item.sourceRange.start,
            duration: sourceOffset
        )
        let rightRange = TimeRange(
            start: item.sourceRange.start + sourceOffset,
            duration: item.sourceRange.duration - sourceOffset
        )
        let leftWindow = TimeRange(start: .zero, duration: sourceOffset)
        let rightWindow = TimeRange(
            start: sourceOffset,
            duration: item.sourceRange.duration - sourceOffset
        )
        let leftEffects = item.effects.compactMap { sliced($0, to: leftWindow, shiftingBy: .zero) }
        let rightEffects = item.effects.compactMap {
            sliced($0, to: rightWindow, shiftingBy: sourceOffset)
        }

        var rightItem = item
        rightItem.id = rightItemID
        rightItem.sourceRange = rightRange
        rightItem.effects = rightEffects

        var operations = removeAllEffects(from: item)
        operations.append(.setSourceRange(itemID, leftRange))
        operations.append(contentsOf: leftEffects.map { .addEffect(itemID, $0) })
        operations.append(.insertItem(rightItem, track: .video, index: index + 1))
        return GraphPatch(ops: operations, label: "Split Clip", origin: .user)
    }

    public static func trimClip(
        in document: ProjectDocument,
        itemID: ItemID,
        to requestedRange: TimeRange,
        assetDuration: RationalTime
    ) throws -> GraphPatch {
        guard let item = document.timeline.video.first(where: { $0.id == itemID }) else {
            throw ModelError.itemNotFound(itemID)
        }
        guard assetDuration >= .zero else {
            throw ModelError.rangeExceedsAsset(
                itemID,
                requested: requestedRange,
                assetDuration: assetDuration
            )
        }
        let assetRange = TimeRange(start: .zero, duration: assetDuration)
        let range = requestedRange.clamped(to: assetRange)
        let retainedInOldLocalTime = TimeRange(
            start: range.start - item.sourceRange.start,
            duration: range.duration
        )
        let effects = item.effects.compactMap {
            sliced($0, to: retainedInOldLocalTime, shiftingBy: retainedInOldLocalTime.start)
        }

        var operations = removeAllEffects(from: item)
        operations.append(.setSourceRange(itemID, range))
        operations.append(contentsOf: effects.map { .addEffect(itemID, $0) })
        return GraphPatch(ops: operations, label: "Trim Clip", origin: .user)
    }

    public static func reorderClip(
        _ itemID: ItemID,
        toIndex index: Int
    ) -> GraphPatch {
        GraphPatch(
            ops: [.moveItem(itemID, toIndex: index)],
            label: "Reorder Clips",
            origin: .user
        )
    }

    public static func setSpeed(
        of itemID: ItemID,
        to speed: Double
    ) -> GraphPatch {
        GraphPatch(
            ops: [.setSpeed(itemID, speed)],
            label: "Change Speed",
            origin: .user
        )
    }
}

extension TimelineEditPlanner {
    fileprivate static func removeAllEffects(from item: TimelineItem) -> [GraphOp] {
        item.effects.reversed().map { .removeEffect(item.id, $0.id) }
    }

    fileprivate static func sliced(
        _ effect: Effect,
        to window: TimeRange,
        shiftingBy offset: RationalTime
    ) -> Effect? {
        let intersection = effect.range.clamped(to: window)
        guard intersection.duration > .zero else { return nil }
        return effect.replacingRange(
            TimeRange(
                start: intersection.start - offset,
                duration: intersection.duration
            )
        )
    }
}
