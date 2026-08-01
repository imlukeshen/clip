import Foundation

/// A half-open range of deterministic media time.
public struct TimeRange: Codable, Sendable, Hashable {
    /// The start in the owning time domain.
    public var start: RationalTime

    /// The nonnegative length of the range.
    public var duration: RationalTime

    /// Creates a time range.
    public init(start: RationalTime, duration: RationalTime) {
        self.start = start
        self.duration = duration
    }

    /// The first timestamp outside the range.
    public var end: RationalTime {
        start + duration
    }

    /// Returns whether two nonempty half-open ranges overlap.
    public func intersects(_ other: TimeRange) -> Bool {
        duration > .zero && other.duration > .zero && start < other.end && other.start < end
    }

    /// Returns the intersection with another range, or an empty range at the nearest boundary.
    public func clamped(to other: TimeRange) -> TimeRange {
        let clampedStart = max(start, other.start)
        let clampedEnd = min(end, other.end)
        return TimeRange(
            start: min(clampedStart, clampedEnd),
            duration: max(clampedEnd - clampedStart, .zero)
        )
    }
}
