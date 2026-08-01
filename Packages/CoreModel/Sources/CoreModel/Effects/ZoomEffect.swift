import Foundation

/// A clip-local animated zoom.
public struct ZoomEffect: Codable, Sendable, Equatable {
    public var id: EffectID
    public var range: TimeRange
    public var center: NormalizedPoint
    public var scale: Double
    public var rampIn: RationalTime
    public var rampOut: RationalTime
    public var easing: Easing
    public var source: EffectSource

    public init(
        id: EffectID,
        range: TimeRange,
        center: NormalizedPoint,
        scale: Double,
        rampIn: RationalTime = RationalTime(seconds: 0.42),
        rampOut: RationalTime = RationalTime(seconds: 0.42),
        easing: Easing = .smoothstep,
        source: EffectSource = .manual
    ) {
        self.id = id
        self.range = range
        self.center = center
        self.scale = scale
        self.rampIn = rampIn
        self.rampOut = rampOut
        self.easing = easing
        self.source = source
    }
}
