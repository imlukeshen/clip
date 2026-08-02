import Foundation

/// A clip-local animated zoom. Legacy ramp fields remain canonical for migrated
/// projects until the first general keyframe is edited.
public struct ZoomEffect: Codable, Sendable, Equatable {
    public var id: EffectID
    public var range: TimeRange
    public var center: NormalizedPoint
    public var scale: Double
    public var rampIn: RationalTime
    public var rampOut: RationalTime
    public var easing: Easing
    public var source: EffectSource
    public var scaleAnimation: Animatable<Double>
    public var centerAnimation: Animatable<NormalizedPoint>
    public var preservesLegacyTiming: Bool

    public init(
        id: EffectID,
        range: TimeRange,
        center: NormalizedPoint,
        scale: Double,
        rampIn: RationalTime = RationalTime(seconds: 0.42),
        rampOut: RationalTime = RationalTime(seconds: 0.42),
        easing: Easing = .smoothstep,
        source: EffectSource = .manual,
        scaleAnimation: Animatable<Double>? = nil,
        centerAnimation: Animatable<NormalizedPoint>? = nil,
        preservesLegacyTiming: Bool = true
    ) {
        self.id = id
        self.range = range
        self.center = center
        self.scale = scale
        self.rampIn = rampIn
        self.rampOut = rampOut
        self.easing = easing
        self.source = source
        self.scaleAnimation =
            scaleAnimation
            ?? Self.legacyAnimation(
                range: range,
                target: scale,
                identity: 1,
                rampIn: rampIn,
                rampOut: rampOut,
                easing: easing
            )
        self.centerAnimation =
            centerAnimation
            ?? Self.legacyAnimation(
                range: range,
                target: center,
                identity: NormalizedPoint(x: 0.5, y: 0.5),
                rampIn: rampIn,
                rampOut: rampOut,
                easing: easing
            )
        self.preservesLegacyTiming = preservesLegacyTiming
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case range
        case center
        case scale
        case rampIn
        case rampOut
        case easing
        case source
        case scaleAnimation
        case centerAnimation
        case preservesLegacyTiming
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(EffectID.self, forKey: .id)
        let range = try container.decode(TimeRange.self, forKey: .range)
        let center = try container.decode(NormalizedPoint.self, forKey: .center)
        let scale = try container.decode(Double.self, forKey: .scale)
        let rampIn = try container.decode(RationalTime.self, forKey: .rampIn)
        let rampOut = try container.decode(RationalTime.self, forKey: .rampOut)
        let easing = try container.decode(Easing.self, forKey: .easing)
        let source = try container.decode(EffectSource.self, forKey: .source)
        let decodedScale = try container.decodeIfPresent(
            Animatable<Double>.self,
            forKey: .scaleAnimation
        )
        let decodedCenter = try container.decodeIfPresent(
            Animatable<NormalizedPoint>.self,
            forKey: .centerAnimation
        )
        self.init(
            id: id,
            range: range,
            center: center,
            scale: scale,
            rampIn: rampIn,
            rampOut: rampOut,
            easing: easing,
            source: source,
            scaleAnimation: decodedScale,
            centerAnimation: decodedCenter,
            preservesLegacyTiming: try container.decodeIfPresent(
                Bool.self,
                forKey: .preservesLegacyTiming
            ) ?? true
        )
    }

    private static func legacyAnimation<Value: AnimatableValue>(
        range: TimeRange,
        target: Value,
        identity: Value,
        rampIn: RationalTime,
        rampOut: RationalTime,
        easing: Easing
    ) -> Animatable<Value> {
        var keyframes: [Keyframe<Value>] = []
        if rampIn > .zero {
            keyframes.append(Keyframe(time: range.start, value: identity))
            keyframes.append(Keyframe(time: range.start + rampIn, value: target, easing: easing))
        } else {
            keyframes.append(Keyframe(time: range.start, value: target))
        }
        if rampOut > .zero {
            keyframes.append(Keyframe(time: range.end - rampOut, value: target))
            keyframes.append(Keyframe(time: range.end, value: identity, easing: easing))
        } else {
            keyframes.append(Keyframe(time: range.end, value: target))
        }
        return Animatable(constant: target, keyframes: keyframes)
    }
}
