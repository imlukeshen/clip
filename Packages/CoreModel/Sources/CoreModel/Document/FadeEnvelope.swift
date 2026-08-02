import Foundation

/// Non-destructive fade handles measured in item timeline time.
public struct FadeEnvelope: Codable, Sendable, Equatable {
    public var fadeIn: RationalTime
    public var fadeOut: RationalTime

    public init(fadeIn: RationalTime = .zero, fadeOut: RationalTime = .zero) {
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public static let none = FadeEnvelope()

    public func value(at localTime: RationalTime, duration: RationalTime) -> Double {
        let leading =
            fadeIn > .zero
            ? min(max(localTime.seconds / fadeIn.seconds, 0), 1)
            : 1
        let remaining = duration - localTime
        let trailing =
            fadeOut > .zero
            ? min(max(remaining.seconds / fadeOut.seconds, 0), 1)
            : 1
        return min(leading, trailing)
    }
}
