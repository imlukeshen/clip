import CoreModel
import Foundation

enum MetadataCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let interval = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            let value = try container.decode(String.self)
            if let date = preciseISO8601.date(from: value) ?? legacyISO8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date \(value)"
            )
        }
        return try decoder.decode(type, from: data)
    }

    private static var preciseISO8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var legacyISO8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
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
