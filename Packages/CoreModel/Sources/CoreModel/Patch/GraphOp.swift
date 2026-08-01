import Foundation

/// One deterministic edit-graph mutation.
public enum GraphOp: Codable, Sendable, Equatable {
    case insertItem(TimelineItem, track: TrackKind, index: Int)
    case removeItem(ItemID)
    case moveItem(ItemID, toIndex: Int)
    case setSourceRange(ItemID, TimeRange)
    case setSpeed(ItemID, Double)
    case setEnabled(ItemID, Bool)
    /// Adds an effect at the end, or at an exact index when generated for undo.
    case addEffect(ItemID, Effect, index: Int? = nil)
    case removeEffect(ItemID, EffectID)
    case updateEffect(ItemID, Effect)
    case setCaptions([CaptionSegment])
    case setCanvas(CanvasSpec)
    case rename(String)
}
