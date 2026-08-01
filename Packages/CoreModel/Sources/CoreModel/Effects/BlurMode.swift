import Foundation

/// A blur renderer and its strength.
public enum BlurMode: Codable, Sendable, Equatable {
    case gaussian(radius: Double)
    case pixelate(size: Double)

    private enum CodingKeys: String, CodingKey {
        case kind
        case radius
        case size
    }

    private enum Kind: String, Codable {
        case gaussian
        case pixelate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .gaussian:
            self = .gaussian(radius: try container.decode(Double.self, forKey: .radius))
        case .pixelate:
            self = .pixelate(size: try container.decode(Double.self, forKey: .size))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gaussian(let radius):
            try container.encode(Kind.gaussian, forKey: .kind)
            try container.encode(radius, forKey: .radius)
        case .pixelate(let size):
            try container.encode(Kind.pixelate, forKey: .kind)
            try container.encode(size, forKey: .size)
        }
    }
}
