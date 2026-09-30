import CoreModel
import Foundation
import PDFEngine
import Testing

@testable import ReelAppCore

@Suite("PDF glyph text search")
struct PDFGlyphTextSearchTests {
    @Test("A match covers the word and not the sentence around it")
    func matchIsTightToTheWord() throws {
        let glyphs = line("hello jiawei there", startingAt: 0, width: 0.05)
        let found = PDFGlyphTextSearch.matches(of: "jiawei", in: glyphs)
        #expect(found.count == 1)

        // Six glyphs starting at index 6, so x spans 0.30 to 0.60. Redacting the
        // span that contains the name would black out the whole line instead.
        let rect = try #require(found.first?.rect)
        #expect(abs(rect.minX - 0.30) < 0.001)
        #expect(abs(rect.maxX - 0.60) < 0.001)
    }

    @Test("Every occurrence is found, not just the first")
    func findsEveryOccurrence() {
        let glyphs = line("ab ab ab", startingAt: 0, width: 0.05)
        #expect(PDFGlyphTextSearch.matches(of: "ab", in: glyphs).count == 3)
    }

    @Test("Matching ignores case and accents")
    func matchingIsForgiving() {
        let glyphs = line("Jiäwei", startingAt: 0, width: 0.05)
        #expect(PDFGlyphTextSearch.matches(of: "jiawei", in: glyphs).count == 1)
    }

    @Test("Text absent from the page yields nothing")
    func absentTextFindsNothing() {
        let glyphs = line("hello there", startingAt: 0, width: 0.05)
        #expect(PDFGlyphTextSearch.matches(of: "jiawei", in: glyphs).isEmpty)
        #expect(PDFGlyphTextSearch.matches(of: "", in: glyphs).isEmpty)
        #expect(PDFGlyphTextSearch.matches(of: "  ", in: glyphs).isEmpty)
    }

    @Test("Glyphs with no resolved bounds still separate their neighbours")
    func unpositionedGlyphsDoNotJoinWords() {
        // A glyph the engine could not place keeps its character in the string.
        // Dropping it would turn "ab" + "cd" into "abcd" and report a match that
        // is not in the document.
        var glyphs = line("ab", startingAt: 0, width: 0.05)
        glyphs.append(
            PDFTextGlyph(text: " ", bounds: nil, font: nil, fontSize: 12, pageObjectIndex: 0))
        glyphs.append(contentsOf: line("cd", startingAt: 3, width: 0.05))
        #expect(PDFGlyphTextSearch.matches(of: "abcd", in: glyphs).isEmpty)
        #expect(PDFGlyphTextSearch.matches(of: "ab", in: glyphs).count == 1)
    }

    @Test("A match carries surrounding text so occurrences can be told apart")
    func snippetGivesContext() throws {
        let glyphs = line("the name jiawei appears here", startingAt: 0, width: 0.03)
        let snippet = try #require(
            PDFGlyphTextSearch.matches(of: "jiawei", in: glyphs).first?.snippet)
        #expect(snippet.contains("jiawei"))
        #expect(snippet.contains("name"))
    }

    @Test("A combining mark earlier on the page does not shift the match")
    func combiningMarksDoNotDriftTheMatch() throws {
        // Building the haystack as a String merged "e" and a combining acute
        // into one Character, so every index after it named the wrong glyph.
        // The search still found the word and then returned the rectangle of
        // whatever had drifted into its place — on the real document, the match
        // landed twenty characters to the left of the word it had found.
        var glyphs = line("e", startingAt: 0, width: 0.05)
        glyphs.append(
            PDFTextGlyph(
                text: "\u{0301}",
                bounds: CGRect(x: 0.05, y: 0.5, width: 0.01, height: 0.02),
                font: nil, fontSize: 12, pageObjectIndex: 0))
        glyphs.append(contentsOf: line(" jiawei", startingAt: 2, width: 0.05))

        let found = PDFGlyphTextSearch.matches(of: "jiawei", in: glyphs)
        #expect(found.count == 1)
        // Glyphs 3...8 hold "jiawei", so x runs from 0.15 to 0.45.
        let rect = try #require(found.first?.rect)
        #expect(abs(rect.minX - 0.15) < 0.001)
        #expect(abs(rect.maxX - 0.45) < 0.001)
    }

    private func line(_ text: String, startingAt offset: Int, width: Double) -> [PDFTextGlyph] {
        text.enumerated().map { index, character in
            PDFTextGlyph(
                text: String(character),
                bounds: CGRect(
                    x: Double(offset + index) * width, y: 0.5, width: width, height: 0.02),
                font: nil,
                fontSize: 12,
                pageObjectIndex: 0
            )
        }
    }
}
