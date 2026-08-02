import Foundation

/// Failures produced while decoding, validating, or mutating the edit graph.
public enum ModelError: Error, Sendable, Equatable {
    case itemNotFound(ItemID)
    case effectNotFound(ItemID, EffectID)
    case indexOutOfRange(Int, count: Int)
    case invalidSpeed(Double)
    case rangeExceedsAsset(
        ItemID,
        requested: TimeRange,
        assetDuration: RationalTime
    )
    case schemaTooNew(found: Int, supported: Int)
    case invalidRange(TimeRange)
    case invalidCanvas(width: Int, height: Int)
    case duplicateItem(ItemID)
    case duplicateEffect(ItemID, EffectID)
    case effectRangeExceedsItem(ItemID, EffectID)
    case splitTooCloseToBoundary(ItemID, minimumDistance: RationalTime)
}
