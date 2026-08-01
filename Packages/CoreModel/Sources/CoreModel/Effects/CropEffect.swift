import Foundation

/// A clip-local crop rectangle.
public struct CropEffect: Codable, Sendable, Equatable {
    public var id: EffectID
    public var range: TimeRange
    public var rect: NormalizedRect

    public init(id: EffectID, range: TimeRange, rect: NormalizedRect) {
        self.id = id
        self.range = range
        self.rect = rect
    }
}
