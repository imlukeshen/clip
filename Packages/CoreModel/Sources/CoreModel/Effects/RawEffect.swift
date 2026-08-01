import Foundation

/// An unknown future effect retained verbatim as structured JSON.
public struct RawEffect: Codable, Sendable, Equatable {
    public var type: String
    public var id: EffectID
    public var range: TimeRange
    public var rawValue: JSONValue

    public init(type: String, id: EffectID, range: TimeRange, rawValue: JSONValue) {
        self.type = type
        self.id = id
        self.range = range
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Effect.CodingKeys.self)
        type = try fields.decode(String.self, forKey: .type)
        id = try fields.decode(EffectID.self, forKey: .id)
        range = try fields.decode(TimeRange.self, forKey: .range)
        rawValue = try JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}
