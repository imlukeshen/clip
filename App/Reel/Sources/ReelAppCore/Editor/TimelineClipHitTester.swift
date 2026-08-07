import Foundation

/// Resolves pointer intent inside a timeline clip while preserving a usable
/// move target even when the clip is only a few pixels wide.
public enum TimelineClipPointerIntent: Equatable, Sendable {
    case leadingTrim
    case move
    case trailingTrim
}

public enum TimelineClipHitTester {
    public static let maximumTrimHandleWidth = 8.0
    public static let minimumMoveTargetWidth = 12.0

    public static func intent(localX: Double, clipWidth: Double) -> TimelineClipPointerIntent {
        guard clipWidth > 0 else { return .move }
        let x = min(max(localX, 0), clipWidth)
        let trimHandleWidth = min(
            maximumTrimHandleWidth,
            max((clipWidth - minimumMoveTargetWidth) / 2, 0)
        )
        guard trimHandleWidth > 0 else { return .move }
        if x <= trimHandleWidth { return .leadingTrim }
        if x >= clipWidth - trimHandleWidth { return .trailingTrim }
        return .move
    }
}
