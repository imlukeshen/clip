import Foundation

/// The quality and offset of cursor-event alignment to an asset.
public enum Alignment: Codable, Sendable, Equatable {
    case exact(offset: RationalTime)
    case estimated(offset: RationalTime, confidence: Double)
    case unavailable(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case offset
        case confidence
        case reason
    }

    private enum Kind: String, Codable {
        case exact
        case estimated
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .exact:
            self = .exact(offset: try container.decode(RationalTime.self, forKey: .offset))
        case .estimated:
            self = .estimated(
                offset: try container.decode(RationalTime.self, forKey: .offset),
                confidence: try container.decode(Double.self, forKey: .confidence)
            )
        case .unavailable:
            self = .unavailable(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exact(let offset):
            try container.encode(Kind.exact, forKey: .kind)
            try container.encode(offset, forKey: .offset)
        case .estimated(let offset, let confidence):
            try container.encode(Kind.estimated, forKey: .kind)
            try container.encode(offset, forKey: .offset)
            try container.encode(confidence, forKey: .confidence)
        case .unavailable(let reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}
