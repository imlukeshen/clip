import Foundation

/// A deterministic media timestamp expressed in 90,000 ticks per second.
public struct RationalTime: Codable, Sendable, Hashable, Comparable {
    /// The canonical number of ticks per second.
    public static let timescale: Int32 = 90_000

    /// A zero timestamp.
    public static let zero = RationalTime(value: 0)

    /// The timestamp in canonical ticks.
    public var value: Int64

    /// The serialized timescale. Reel always normalizes this to 90,000.
    public private(set) var timescale: Int32

    /// Creates a timestamp, normalizing values expressed at another timescale.
    public init(value: Int64, timescale: Int32 = RationalTime.timescale) {
        precondition(timescale > 0, "A media timescale must be positive")
        if timescale == RationalTime.timescale {
            self.value = value
        } else {
            self.value = Int64(
                (Double(value) * Double(RationalTime.timescale) / Double(timescale)).rounded()
            )
        }
        self.timescale = RationalTime.timescale
    }

    /// Creates a timestamp by rounding seconds to the nearest canonical tick.
    public init(seconds: Double) {
        precondition(seconds.isFinite, "A media timestamp must be finite")
        self.init(value: Int64((seconds * Double(RationalTime.timescale)).rounded()))
    }

    /// The timestamp expressed as seconds.
    public var seconds: Double {
        Double(value) / Double(RationalTime.timescale)
    }

    /// Adds two timestamps.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(value: lhs.value + rhs.value)
    }

    /// Subtracts one timestamp from another.
    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(value: lhs.value - rhs.value)
    }

    /// Scales this timestamp, rounding to the nearest canonical tick.
    public func scaled(by factor: Double) -> Self {
        precondition(factor.isFinite, "A media time scale factor must be finite")
        return Self(value: Int64((Double(value) * factor).rounded()))
    }

    /// Restricts this timestamp to a closed time range.
    public func clamped(to range: TimeRange) -> Self {
        min(max(self, range.start), range.end)
    }

    /// Compares timestamps using canonical ticks.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case timescale
    }

    /// Decodes and normalizes a timestamp to Reel's canonical timescale.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedValue = try container.decode(Int64.self, forKey: .value)
        let decodedTimescale = try container.decode(Int32.self, forKey: .timescale)
        guard decodedTimescale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .timescale,
                in: container,
                debugDescription: "A media timescale must be positive"
            )
        }
        self.init(value: decodedValue, timescale: decodedTimescale)
    }

    /// Encodes a timestamp using Reel's canonical timescale.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(RationalTime.timescale, forKey: .timescale)
    }
}
