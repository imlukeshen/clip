import Foundation

/// A clip-local privacy or focus blur.
public struct BlurEffect: Codable, Sendable, Equatable {
    public var id: EffectID
    public var range: TimeRange
    public var regions: [TimedRegion]
    public var mode: BlurMode
    public var isDestructiveOnExport: Bool

    public init(
        id: EffectID,
        range: TimeRange,
        regions: [TimedRegion],
        mode: BlurMode,
        isDestructiveOnExport: Bool
    ) {
        self.id = id
        self.range = range
        self.regions = regions
        self.mode = mode
        self.isDestructiveOnExport = isDestructiveOnExport
    }
}
