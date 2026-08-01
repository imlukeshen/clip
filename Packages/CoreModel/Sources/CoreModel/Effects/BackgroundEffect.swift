import Foundation

/// A clip-local presentation background.
public struct BackgroundEffect: Codable, Sendable, Equatable {
    public var id: EffectID
    public var range: TimeRange
    public var padding: Double
    public var cornerRadius: Double
    public var style: BackgroundStyle
    public var shadow: ShadowSpec?

    public init(
        id: EffectID,
        range: TimeRange,
        padding: Double,
        cornerRadius: Double,
        style: BackgroundStyle,
        shadow: ShadowSpec? = nil
    ) {
        self.id = id
        self.range = range
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.style = style
        self.shadow = shadow
    }
}
