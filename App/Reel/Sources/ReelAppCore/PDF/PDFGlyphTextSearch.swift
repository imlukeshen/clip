import CoreModel
import Foundation
import PDFEngine

/// Finds a string in a page's glyphs and returns the rectangle it occupies.
///
/// Works over glyphs rather than spans so the rectangle covers the match and
/// nothing else. A span is a formatting run — often a whole sentence — and
/// redacting one to hide a name inside it removes the sentence.
public enum PDFGlyphTextSearch {
    /// Every occurrence of `query` among `glyphs`, case- and diacritic-insensitive.
    ///
    /// Glyphs whose bounds the engine could not resolve are kept in the string
    /// being searched but contribute no geometry: dropping them would join words
    /// either side of them and invent matches that are not in the document.
    public static func matches(
        of query: String,
        in glyphs: [PDFTextGlyph],
        contextCharacters: Int = 24
    ) -> [(rect: CGRect, snippet: String)] {
        let needle = Array(fold(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard !needle.isEmpty, !glyphs.isEmpty else { return [] }

        // Matched over parallel arrays rather than a String. Building a String
        // from the glyphs' characters re-segments them into grapheme clusters,
        // so a combining sequence anywhere on the page merges two characters
        // into one and every index after it refers to the wrong glyph. That is
        // silent: the search still finds the word, and then redacts whatever
        // sits at the drifted offset — on a real page, twenty characters away.
        var haystack: [Character] = []
        var owners: [Int] = []
        for (index, glyph) in glyphs.enumerated() {
            for character in fold(glyph.text) {
                haystack.append(character)
                owners.append(index)
            }
        }
        guard haystack.count >= needle.count else { return [] }

        var results: [(rect: CGRect, snippet: String)] = []
        var start = 0
        while start <= haystack.count - needle.count {
            guard Array(haystack[start..<(start + needle.count)]) == needle else {
                start += 1
                continue
            }
            let matched = Set(owners[start..<(start + needle.count)])
            if let rect = union(of: matched.compactMap { glyphs[$0].bounds }) {
                results.append(
                    (
                        rect,
                        snippet(
                            in: haystack, around: start, length: needle.count,
                            width: contextCharacters)
                    ))
            }
            start += needle.count
        }
        return results
    }

    /// Case- and diacritic-insensitive, and stable in length per character.
    ///
    /// Folded one character at a time so a character that folds to several — ß
    /// becoming ss — contributes each of them with the same owning glyph,
    /// keeping the haystack and its owners the same length.
    private static func fold(_ text: String) -> [Character] {
        text.flatMap { character in
            Array(
                String(character).folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
    }

    private static func union(of rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func snippet(
        in haystack: [Character],
        around start: Int,
        length: Int,
        width: Int
    ) -> String {
        let lower = max(start - width, 0)
        let upper = min(start + length + width, haystack.count)
        return String(haystack[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
