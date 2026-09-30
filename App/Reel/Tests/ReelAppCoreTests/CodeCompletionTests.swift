import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Code completion")
struct CodeCompletionTests {
    @Test("Names from the buffer come before keywords and built-ins")
    func bufferNamesComeFirst() {
        let source = "def printable_area(shape):\n    return shape\n"
        let suggestions = CodeCompletion.suggestions(
            forPrefix: "pri",
            in: source,
            language: .python
        )
        #expect(suggestions.first == "printable_area")
        #expect(suggestions.contains("print"))
    }

    @Test("Keywords and built-ins complete in an empty file")
    func vocabularyCompletes() {
        let suggestions = CodeCompletion.suggestions(forPrefix: "el", in: "", language: .python)
        #expect(suggestions.contains("elif"))
        #expect(suggestions.contains("else"))
        #expect(!suggestions.contains("el"))
    }

    @Test("Every programming language completes its own vocabulary")
    func everyLanguageCompletes() {
        #expect(
            CodeCompletion.suggestions(forPrefix: "gu", in: "", language: .swift).contains("guard"))
        #expect(
            CodeCompletion.suggestions(forPrefix: "fa", in: "", language: .go).contains(
                "fallthrough"))
        #expect(
            CodeCompletion.suggestions(forPrefix: "pri", in: "", language: .rust).contains(
                "println"))
        #expect(
            CodeCompletion.suggestions(forPrefix: "con", in: "", language: .javascript).contains(
                "console"))
        #expect(
            CodeCompletion.suggestions(forPrefix: "esa", in: "", language: .bash).contains("esac"))
        #expect(!CodeCompletion.isAvailable(for: .latex))
        #expect(!CodeCompletion.isAvailable(for: .markdown))
    }

    @Test("SQL completes whatever case it is typed in")
    func sqlIgnoresCase() {
        #expect(
            CodeCompletion.suggestions(forPrefix: "sel", in: "", language: .sql).contains("SELECT"))
    }

    @Test("The prefix is the identifier ending at the caret")
    func prefixRangeFindsIdentifier() {
        let source = "total = my_val" as NSString
        #expect(
            CodeCompletion.prefixRange(endingAt: source.length, in: source)
                == NSRange(location: 8, length: 6)
        )
        #expect(CodeCompletion.prefixRange(endingAt: 7, in: source) == nil)
    }

    @Test("A number is never treated as a name to complete")
    func numbersDoNotComplete() {
        let source = "x = 314" as NSString
        #expect(CodeCompletion.prefixRange(endingAt: source.length, in: source) == nil)
    }
}
