import Foundation

/// A reference to an immutable asset over a selected source range.
public struct TimelineItem: Codable, Sendable, Equatable, Identifiable {
    public var id: ItemID
    public var assetID: AssetID
    public var sourceRange: TimeRange
    /// The explicit project time at which this item begins.
    public var timelineStart: RationalTime
    public var speed: Double
    public var effects: [Effect]
    public var isEnabled: Bool
    public var transform: Animatable<Transform2D>
    public var opacity: Animatable<Double>
    public var blendMode: BlendMode
    public var videoFade: FadeEnvelope
    public var audioFade: FadeEnvelope
    /// Clips with the same value are treated as one nested editing group while
    /// remaining independent media items for deterministic playback/export.
    public var nestID: String?

    public init(
        id: ItemID,
        assetID: AssetID,
        sourceRange: TimeRange,
        timelineStart: RationalTime = .zero,
        speed: Double = 1,
        effects: [Effect] = [],
        isEnabled: Bool = true,
        transform: Transform2D = .identity,
        opacity: Double = 1,
        transformAnimation: Animatable<Transform2D>? = nil,
        opacityAnimation: Animatable<Double>? = nil,
        blendMode: BlendMode = .normal,
        videoFade: FadeEnvelope = .none,
        audioFade: FadeEnvelope = .none,
        nestID: String? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.speed = speed
        self.effects = effects
        self.isEnabled = isEnabled
        self.transform = transformAnimation ?? Animatable(constant: transform)
        self.opacity = opacityAnimation ?? Animatable(constant: opacity)
        self.blendMode = blendMode
        self.videoFade = videoFade
        self.audioFade = audioFade
        self.nestID = nestID
    }

    /// The duration occupied by this item in timeline time.
    public var timelineDuration: RationalTime {
        sourceRange.duration.scaled(by: 1 / speed)
    }

    /// The project time immediately after this item.
    public var timelineEnd: RationalTime {
        timelineStart + timelineDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case assetID
        case sourceRange
        case timelineStart
        case speed
        case effects
        case isEnabled
        case transform
        case opacity
        case blendMode
        case videoFade
        case audioFade
        case nestID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ItemID.self, forKey: .id)
        assetID = try container.decode(AssetID.self, forKey: .assetID)
        sourceRange = try container.decode(TimeRange.self, forKey: .sourceRange)
        timelineStart =
            try container.decodeIfPresent(RationalTime.self, forKey: .timelineStart) ?? .zero
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        transform =
            try container.decodeIfPresent(Animatable<Transform2D>.self, forKey: .transform)
            ?? Animatable(constant: .identity)
        opacity =
            try container.decodeIfPresent(Animatable<Double>.self, forKey: .opacity)
            ?? Animatable(constant: 1)
        blendMode = try container.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? .normal
        videoFade = try container.decodeIfPresent(FadeEnvelope.self, forKey: .videoFade) ?? .none
        audioFade = try container.decodeIfPresent(FadeEnvelope.self, forKey: .audioFade) ?? .none
        nestID = try container.decodeIfPresent(String.self, forKey: .nestID)
    }
}
