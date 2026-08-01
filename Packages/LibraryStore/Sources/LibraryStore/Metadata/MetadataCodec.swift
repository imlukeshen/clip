import CoreModel
import Foundation

enum MetadataCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    static func encodeJSONValue(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw LibraryError.corruptMetadata("preferred transform")
        }
        return result
    }

    static func decodeJSONValue(_ value: String?) throws -> JSONValue? {
        guard let value else { return nil }
        guard let data = value.data(using: .utf8) else {
            throw LibraryError.corruptMetadata("preferred transform")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
