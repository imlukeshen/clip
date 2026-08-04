import CoreModel
import Foundation
import LibraryStore

public enum SearchQueryParser {
    public static let maximumLength = 512

    public static func parse(_ query: SearchQuery) throws -> ParsedSearchQuery {
        guard query.text.count <= maximumLength else { throw SearchError.queryTooLong }
        var filters = query.filters
        var terms: [String] = []
        var phrases: [String] = []

        for lexeme in lex(query.text) where !lexeme.value.isEmpty {
            if lexeme.isQuoted {
                phrases.append(lexeme.value)
                continue
            }
            guard let separator = lexeme.value.firstIndex(of: ":") else {
                terms.append(lexeme.value)
                continue
            }
            let key = lexeme.value[..<separator].lowercased()
            let value = String(lexeme.value[lexeme.value.index(after: separator)...])
            guard !value.isEmpty else { throw SearchError.invalidFilter(lexeme.value) }
            switch key {
            case "kind":
                guard let kind = kind(from: value) else {
                    throw SearchError.invalidFilter(lexeme.value)
                }
                filters.kind = kind
            case "after":
                guard let date = day(from: value) else {
                    throw SearchError.invalidFilter(lexeme.value)
                }
                filters.after = date
            case "before":
                guard let date = day(from: value, endOfDay: true) else {
                    throw SearchError.invalidFilter(lexeme.value)
                }
                filters.before = date
            case "in":
                filters.folder = value
            case "hasaudio", "has-audio":
                guard let hasAudio = boolean(from: value) else {
                    throw SearchError.invalidFilter(lexeme.value)
                }
                filters.hasAudio = hasAudio
            case "duration":
                guard applyDuration(value, to: &filters) else {
                    throw SearchError.invalidFilter(lexeme.value)
                }
            default:
                terms.append(lexeme.value)
            }
        }
        return ParsedSearchQuery(
            terms: terms,
            phrases: phrases,
            filters: filters,
            mode: phrases.isEmpty ? query.mode : .keyword
        )
    }

    private struct Lexeme {
        var value: String
        var isQuoted: Bool
    }

    /// Splits on whitespace outside quotes and keeps `in:"Client Work"` together.
    private static func lex(_ text: String) -> [Lexeme] {
        var result: [Lexeme] = []
        var value = ""
        var isInsideQuote = false
        var beganWithQuote = false
        var sawPrefixBeforeQuote = false

        func appendCurrent() {
            guard !value.isEmpty else { return }
            result.append(
                Lexeme(value: value, isQuoted: beganWithQuote && !sawPrefixBeforeQuote)
            )
            value = ""
            beganWithQuote = false
            sawPrefixBeforeQuote = false
        }

        for character in text {
            if character == "\"" {
                if !isInsideQuote {
                    beganWithQuote = value.isEmpty
                    sawPrefixBeforeQuote = !value.isEmpty
                }
                isInsideQuote.toggle()
            } else if character.isWhitespace, !isInsideQuote {
                appendCurrent()
            } else {
                value.append(character)
            }
        }
        appendCurrent()
        return result
    }

    private static func kind(from value: String) -> AssetKind? {
        switch value.lowercased() {
        case "video", "videos": .video
        case "image", "images", "photo", "photos": .image
        case "audio": .audio
        case "document", "documents", "pdf", "pdfs": .document
        case "text", "code": .text
        default: nil
        }
    }

    private static func day(from value: String, endOfDay: Bool = false) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return nil }
        return endOfDay ? date.addingTimeInterval(86_400 - 0.001) : date
    }

    private static func boolean(from value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1": true
        case "false", "no", "0": false
        default: nil
        }
    }

    private static func applyDuration(_ value: String, to filters: inout SearchFilters) -> Bool {
        if value.hasPrefix(">") {
            guard let seconds = seconds(from: String(value.dropFirst())) else { return false }
            filters.minimumDuration = RationalTime(seconds: seconds)
            return true
        }
        if value.hasPrefix("<") {
            guard let seconds = seconds(from: String(value.dropFirst())) else { return false }
            filters.maximumDuration = RationalTime(seconds: seconds)
            return true
        }
        let bounds = value.components(separatedBy: "..")
        if bounds.count == 2,
            let minimum = seconds(from: bounds[0]),
            let maximum = seconds(from: bounds[1]),
            minimum <= maximum
        {
            filters.minimumDuration = RationalTime(seconds: minimum)
            filters.maximumDuration = RationalTime(seconds: maximum)
            return true
        }
        guard let exact = seconds(from: value) else { return false }
        filters.minimumDuration = RationalTime(seconds: exact)
        filters.maximumDuration = RationalTime(seconds: exact)
        return true
    }

    private static func seconds(from value: String) -> Double? {
        let lower = value.lowercased()
        let multiplier: Double
        let number: Substring
        if lower.hasSuffix("ms") {
            multiplier = 0.001
            number = lower.dropLast(2)
        } else if lower.hasSuffix("s") {
            multiplier = 1
            number = lower.dropLast()
        } else if lower.hasSuffix("m") {
            multiplier = 60
            number = lower.dropLast()
        } else if lower.hasSuffix("h") {
            multiplier = 3_600
            number = lower.dropLast()
        } else {
            multiplier = 1
            number = Substring(lower)
        }
        guard let value = Double(number), value >= 0, value.isFinite else { return nil }
        return value * multiplier
    }
}
