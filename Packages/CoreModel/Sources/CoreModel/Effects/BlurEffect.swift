import Foundation

/// A clip-local privacy or focus blur.
public struct BlurEffect: Codable, Sendable, Equatable {
    public var id: EffectID
    public var range: TimeRange
    public var regions: [TimedRegion]
    public var mode: BlurMode
    public var isDestructiveOnExport: Bool
    /// Animates the Gaussian radius or pixel block size while retaining the
    /// existing BlurMode wire representation.
    public var intensityAnimation: Animatable<Double>?

    public init(
        id: EffectID,
        range: TimeRange,
        regions: [TimedRegion],
        mode: BlurMode,
        isDestructiveOnExport: Bool,
        intensityAnimation: Animatable<Double>? = nil
    ) {
        self.id = id
        self.range = range
        self.regions = regions
        self.mode = mode
        self.isDestructiveOnExport = isDestructiveOnExport
        self.intensityAnimation = intensityAnimation
    }

    public func intensity(at time: RationalTime) -> Double {
        intensityAnimation?.value(at: time) ?? mode.constantIntensity
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case range
        case regions
        case mode
        case isDestructiveOnExport
        case intensityAnimation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(EffectID.self, forKey: .id)
        range = try container.decode(TimeRange.self, forKey: .range)
        regions = try container.decode([TimedRegion].self, forKey: .regions)
        mode = try container.decode(BlurMode.self, forKey: .mode)
        isDestructiveOnExport = try container.decode(Bool.self, forKey: .isDestructiveOnExport)
        intensityAnimation = try container.decodeIfPresent(
            Animatable<Double>.self,
            forKey: .intensityAnimation
        )
    }
}

extension BlurMode {
    public var constantIntensity: Double {
        switch self {
        case .gaussian(let radius): radius
        case .pixelate(let size): size
        }
    }
}
