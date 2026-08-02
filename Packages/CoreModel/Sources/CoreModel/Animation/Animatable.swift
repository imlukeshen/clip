import Foundation

public protocol AnimatableValue: Codable, Sendable, Equatable {
    static func interpolate(from: Self, to: Self, progress: Double) -> Self
}

public struct Keyframe<Value: AnimatableValue>: Codable, Sendable, Equatable {
    public var time: RationalTime
    public var value: Value
    public var easing: Easing

    public init(time: RationalTime, value: Value, easing: Easing = .linear) {
        self.time = time
        self.value = value
        self.easing = easing
    }
}

/// A constant value with an optional ordered keyframe curve. The decoder also
/// accepts a legacy scalar, making migrations mechanical for existing projects.
public struct Animatable<Value: AnimatableValue>: Codable, Sendable, Equatable {
    public var keyframes: [Keyframe<Value>]
    public var constant: Value

    public init(constant: Value, keyframes: [Keyframe<Value>] = []) {
        self.constant = constant
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    public func value(at time: RationalTime) -> Value {
        guard !keyframes.isEmpty else { return constant }
        if time <= keyframes[0].time { return keyframes[0].value }
        if time >= keyframes[keyframes.count - 1].time {
            return keyframes[keyframes.count - 1].value
        }
        guard let rightIndex = keyframes.firstIndex(where: { $0.time >= time }), rightIndex > 0
        else { return constant }
        let left = keyframes[rightIndex - 1]
        let right = keyframes[rightIndex]
        let interval = right.time - left.time
        guard interval > .zero else { return right.value }
        var progress = (time - left.time).seconds / interval.seconds
        progress = min(max(progress, 0), 1)
        switch right.easing {
        case .linear:
            break
        case .smoothstep, .easeInOut:
            progress = progress * progress * (3 - 2 * progress)
        }
        return Value.interpolate(from: left.value, to: right.value, progress: progress)
    }

    public mutating func setKeyframe(_ keyframe: Keyframe<Value>) {
        keyframes.removeAll { $0.time == keyframe.time }
        keyframes.append(keyframe)
        keyframes.sort { $0.time < $1.time }
    }

    public init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(Value.self) {
            self.init(constant: legacy)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            constant: try container.decode(Value.self, forKey: .constant),
            keyframes: try container.decodeIfPresent(
                [Keyframe<Value>].self,
                forKey: .keyframes
            ) ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case constant
        case keyframes
    }
}

extension Double: AnimatableValue {
    public static func interpolate(from: Double, to: Double, progress: Double) -> Double {
        from + (to - from) * progress
    }
}

extension NormalizedPoint: AnimatableValue {
    public static func interpolate(
        from: NormalizedPoint,
        to: NormalizedPoint,
        progress: Double
    ) -> NormalizedPoint {
        NormalizedPoint(
            x: Double.interpolate(from: from.x, to: to.x, progress: progress),
            y: Double.interpolate(from: from.y, to: to.y, progress: progress)
        )
    }
}

extension Transform2D: AnimatableValue {
    public static func interpolate(
        from: Transform2D,
        to: Transform2D,
        progress: Double
    ) -> Transform2D {
        Transform2D(
            translationX: Double.interpolate(
                from: from.translationX, to: to.translationX, progress: progress),
            translationY: Double.interpolate(
                from: from.translationY, to: to.translationY, progress: progress),
            scaleX: Double.interpolate(from: from.scaleX, to: to.scaleX, progress: progress),
            scaleY: Double.interpolate(from: from.scaleY, to: to.scaleY, progress: progress),
            rotationDegrees: Double.interpolate(
                from: from.rotationDegrees, to: to.rotationDegrees, progress: progress)
        )
    }
}
