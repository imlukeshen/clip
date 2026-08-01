import Foundation

/// A renderable clip-local effect or a losslessly retained future effect.
public enum Effect: Codable, Sendable, Equatable, Identifiable {
    case zoom(ZoomEffect)
    case crop(CropEffect)
    case background(BackgroundEffect)
    case blur(BlurEffect)
    case cursor(CursorEffect)
    case text(TextEffect)
    case unknown(RawEffect)

    public var id: EffectID {
        switch self {
        case .zoom(let value): value.id
        case .crop(let value): value.id
        case .background(let value): value.id
        case .blur(let value): value.id
        case .cursor(let value): value.id
        case .text(let value): value.id
        case .unknown(let value): value.id
        }
    }

    public var range: TimeRange {
        switch self {
        case .zoom(let value): value.range
        case .crop(let value): value.range
        case .background(let value): value.range
        case .blur(let value): value.range
        case .cursor(let value): value.range
        case .text(let value): value.range
        case .unknown(let value): value.range
        }
    }

    public var kind: EffectKind {
        switch self {
        case .zoom: .zoom
        case .crop: .crop
        case .background: .background
        case .blur: .blur
        case .cursor: .cursor
        case .text: .text
        case .unknown(let value): .unknown(value.type)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case range
        case center
        case scale
        case rampIn
        case rampOut
        case easing
        case source
        case rect
        case padding
        case cornerRadius
        case style
        case shadow
        case regions
        case mode
        case isDestructiveOnExport
        case opacity
        case text
        case position
        case fontSize
        case color
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "zoom": self = .zoom(try ZoomEffect(from: decoder))
        case "crop": self = .crop(try CropEffect(from: decoder))
        case "background": self = .background(try BackgroundEffect(from: decoder))
        case "blur": self = .blur(try BlurEffect(from: decoder))
        case "cursor": self = .cursor(try CursorEffect(from: decoder))
        case "text": self = .text(try TextEffect(from: decoder))
        default: self = .unknown(try RawEffect(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .zoom(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("zoom", forKey: .type)
            try container.encode(value.id, forKey: .id)
            try container.encode(value.range, forKey: .range)
            try container.encode(value.center, forKey: .center)
            try container.encode(value.scale, forKey: .scale)
            try container.encode(value.rampIn, forKey: .rampIn)
            try container.encode(value.rampOut, forKey: .rampOut)
            try container.encode(value.easing, forKey: .easing)
            try container.encode(value.source, forKey: .source)
        case .crop(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("crop", forKey: .type)
            try container.encode(value.id, forKey: .id)
            try container.encode(value.range, forKey: .range)
            try container.encode(value.rect, forKey: .rect)
        case .background(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("background", forKey: .type)
            try container.encode(value.id, forKey: .id)
            try container.encode(value.range, forKey: .range)
            try container.encode(value.padding, forKey: .padding)
            try container.encode(value.cornerRadius, forKey: .cornerRadius)
            try container.encode(value.style, forKey: .style)
            try container.encodeIfPresent(value.shadow, forKey: .shadow)
        case .blur(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("blur", forKey: .type)
            try container.encode(value.id, forKey: .id)
            try container.encode(value.range, forKey: .range)
            try container.encode(value.regions, forKey: .regions)
            try container.encode(value.mode, forKey: .mode)
            try container.encode(value.isDestructiveOnExport, forKey: .isDestructiveOnExport)
        case .cursor(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("cursor", forKey: .type)
            try container.encode(value.id, forKey: .id)
            try container.encode(value.range, forKey: .range)
            try container.encode(value.scale, forKey: .scale)
            try container.encode(value.opacity, forKey: .opacity)
        case .text(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(value.id, forKey: .id)
            try container.encode(value.range, forKey: .range)
            try container.encode(value.text, forKey: .text)
            try container.encode(value.position, forKey: .position)
            try container.encode(value.fontSize, forKey: .fontSize)
            try container.encode(value.color, forKey: .color)
        case .unknown(let value):
            try value.encode(to: encoder)
        }
    }
}
