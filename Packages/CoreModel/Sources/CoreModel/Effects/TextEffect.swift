import Foundation

/// A clip-local text overlay.
public struct TextEffect: Codable, Sendable, Equatable {
    public var id: EffectID
    public var range: TimeRange
    public var text: String
    public var position: NormalizedPoint
    public var fontSize: Double
    public var color: RGBA

    public init(
        id: EffectID,
        range: TimeRange,
        text: String,
        position: NormalizedPoint,
        fontSize: Double,
        color: RGBA
    ) {
        self.id = id
        self.range = range
        self.text = text
        self.position = position
        self.fontSize = fontSize
        self.color = color
    }
}
