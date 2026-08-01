import Foundation

/// A solid color or immutable image used behind a clip.
public enum BackgroundStyle: Codable, Sendable, Equatable {
    case solid(RGBA)
    case image(AssetID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case color
        case assetID
    }

    private enum Kind: String, Codable {
        case solid
        case image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .solid:
            self = .solid(try container.decode(RGBA.self, forKey: .color))
        case .image:
            self = .image(try container.decode(AssetID.self, forKey: .assetID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let color):
            try container.encode(Kind.solid, forKey: .kind)
            try container.encode(color, forKey: .color)
        case .image(let assetID):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(assetID, forKey: .assetID)
        }
    }
}
