import Foundation

/// A clip-local cursor presentation adjustment.
public struct CursorEffect: Codable, Sendable, Equatable {
    public var id: EffectID
    public var range: TimeRange
    public var scale: Double
    public var opacity: Double

    public init(id: EffectID, range: TimeRange, scale: Double, opacity: Double = 1) {
        self.id = id
        self.range = range
        self.scale = scale
        self.opacity = opacity
    }
}
