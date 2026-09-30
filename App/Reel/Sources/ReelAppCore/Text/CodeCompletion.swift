import CoreModel
import Foundation
import TextEngine

/// Word completion for the code editor: the language's keywords and built-ins,
/// plus every name already written in the buffer.
///
/// Deliberately lexical. clipx is a scratch editor for short programs, not an
/// IDE, so it offers what is on the page and in the language without running a
/// language server.
public enum CodeCompletion {
    /// The most suggestions offered at once, so the list stays scannable.
    public static let maximumSuggestions = 40

    /// Whether completion is offered for `language`.
    public static func isAvailable(for language: LanguageID) -> Bool {
        !LanguageVocabulary.keywords(for: language).isEmpty
    }

    /// The identifier being typed that ends at `location`, if any.
    public static func prefixRange(endingAt location: Int, in source: NSString) -> NSRange? {
        var start = min(max(location, 0), source.length)
        let end = start
        while start > 0, isIdentifierUnit(source.character(at: start - 1)) {
            start -= 1
        }
        guard start < end else { return nil }
        // An identifier cannot start with a digit, so `3.14` never completes.
        guard !isDigit(source.character(at: start)) else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Suggestions that extend `prefix`, closest matches first.
    ///
    /// Names already used in `source` come before keywords and built-ins, since
    /// a short program mostly refers to what it has just defined.
    public static func suggestions(
        forPrefix prefix: String,
        in source: String,
        language: LanguageID
    ) -> [String] {
        guard isAvailable(for: language), !prefix.isEmpty else { return [] }
        // SQL is written in either case, so `sel` should still offer `SELECT`.
        let ignoresCase = language == .sql
        func extends(_ candidate: String) -> Bool {
            ignoresCase
                ? candidate.lowercased().hasPrefix(prefix.lowercased())
                    && candidate.count > prefix.count
                : candidate.hasPrefix(prefix)
        }
        var seen: Set<String> = [prefix]
        var result: [String] = []
        func offer(_ candidates: [String]) {
            for candidate in candidates
            where extends(candidate) && seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        offer(bufferIdentifiers(in: source).sorted())
        offer(LanguageVocabulary.keywords(for: language))
        offer(LanguageVocabulary.builtins(for: language))
        return Array(result.prefix(maximumSuggestions))
    }

    private static func bufferIdentifiers(in source: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]{2,}")
        else { return [] }
        let text = source as NSString
        var names: Set<String> = []
        expression.enumerateMatches(
            in: source,
            range: NSRange(location: 0, length: text.length)
        ) { match, _, _ in
            guard let match else { return }
            names.insert(text.substring(with: match.range))
        }
        return names
    }

    private static func isIdentifierUnit(_ unit: unichar) -> Bool {
        isDigit(unit) || unit == 0x5F || (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x61 && unit <= 0x7A)
    }

    private static func isDigit(_ unit: unichar) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }
}
