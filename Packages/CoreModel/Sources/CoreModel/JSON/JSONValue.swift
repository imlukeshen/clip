import Foundation

/// A lossless JSON value used for tool arguments and forward-compatible model fields.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Returns a member from an object value.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// Decodes this value into a concrete Codable type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }

        do {
            self = .bool(try container.decode(Bool.self))
            return
        } catch DecodingError.typeMismatch {
            // Continue through the JSON sum type.
        }

        do {
            self = .number(try container.decode(Double.self))
            return
        } catch DecodingError.typeMismatch {
            // Continue through the JSON sum type.
        }

        do {
            self = .string(try container.decode(String.self))
            return
        } catch DecodingError.typeMismatch {
            // Continue through the JSON sum type.
        }

        do {
            self = .array(try container.decode([JSONValue].self))
            return
        } catch DecodingError.typeMismatch {
            // The only remaining valid JSON shape is an object.
        }

        self = .object(try container.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
