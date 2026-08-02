import CoreModel
import Foundation

public struct ZoomState: Sendable, Equatable {
    public var center: NormalizedPoint
    public var scale: Double

    public init(center: NormalizedPoint, scale: Double) {
        self.center = center
        self.scale = scale
    }

    public static let identity = ZoomState(
        center: NormalizedPoint(x: 0.5, y: 0.5),
        scale: 1
    )
}

public enum ZoomEvaluator {
    public static func state(
        at time: RationalTime,
        effects: [ZoomEffect]
    ) -> ZoomState {
        guard
            let effect = effects.last(where: {
                time >= $0.range.start && time < $0.range.end
            })
        else {
            return .identity
        }
        if !effect.preservesLegacyTiming {
            let scale = max(effect.scaleAnimation.value(at: time), 1)
            return ZoomState(
                center: clampCentre(effect.centerAnimation.value(at: time), scale: scale),
                scale: scale
            )
        }
        let rampIn = rampProgress(time - effect.range.start, duration: effect.rampIn)
        let rampOut = rampProgress(effect.range.end - time, duration: effect.rampOut)
        let progress = easing(min(rampIn, rampOut), curve: effect.easing)
        let scale = 1 + (max(effect.scale, 1) - 1) * progress
        let center = NormalizedPoint(
            x: 0.5 + (effect.center.x - 0.5) * progress,
            y: 0.5 + (effect.center.y - 0.5) * progress
        )
        return ZoomState(center: clampCentre(center, scale: scale), scale: scale)
    }

    public static func clampCentre(
        _ center: NormalizedPoint,
        scale: Double
    ) -> NormalizedPoint {
        let safeScale = max(scale, 1)
        let maximumOffset = (1 - 1 / safeScale) / 2
        let lower = 0.5 - maximumOffset
        let upper = 0.5 + maximumOffset
        return NormalizedPoint(
            x: min(max(center.x, lower), upper),
            y: min(max(center.y, lower), upper)
        )
    }

    private static func rampProgress(
        _ elapsed: RationalTime,
        duration: RationalTime
    ) -> Double {
        guard duration > .zero else { return 1 }
        return min(max(elapsed.seconds / duration.seconds, 0), 1)
    }

    private static func easing(_ value: Double, curve: Easing) -> Double {
        switch curve {
        case .linear: value
        case .smoothstep, .easeInOut: value * value * (3 - 2 * value)
        }
    }
}
