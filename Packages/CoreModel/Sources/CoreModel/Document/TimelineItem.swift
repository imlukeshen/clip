import Foundation

/// A reference to an immutable asset over a selected source range.
public struct TimelineItem: Codable, Sendable, Equatable, Identifiable {
    public var id: ItemID
    public var assetID: AssetID
    public var sourceRange: TimeRange
    public var speed: Double
    public var effects: [Effect]
    public var isEnabled: Bool

    public init(
        id: ItemID,
        assetID: AssetID,
        sourceRange: TimeRange,
        speed: Double = 1,
        effects: [Effect] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceRange = sourceRange
        self.speed = speed
        self.effects = effects
        self.isEnabled = isEnabled
    }

    /// The duration occupied by this item in timeline time.
    public var timelineDuration: RationalTime {
        sourceRange.duration.scaled(by: 1 / speed)
    }
}
