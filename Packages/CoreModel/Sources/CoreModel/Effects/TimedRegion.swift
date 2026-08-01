import Foundation

/// A normalized region keyframed at clip-local source time.
public struct TimedRegion: Codable, Sendable, Equatable {
    public var time: RationalTime
    public var rect: NormalizedRect

    public init(time: RationalTime, rect: NormalizedRect) {
        self.time = time
        self.rect = rect
    }
}
