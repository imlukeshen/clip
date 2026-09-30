import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Code indentation")
struct CodeIndentationTests {
    @Test("A Python block opens after a trailing colon")
    func indentsAfterColon() {
        #expect(indentation(after: "def area(shape):") == "    ")
        #expect(indentation(after: "    if ready:  # check first") == "        ")
        #expect(indentation(after: "class Square:") == "    ")
    }

    @Test("A colon inside a string or comment does not open a block")
    func ignoresColonsInStringsAndComments() {
        #expect(indentation(after: "    label = \"a:\"") == "    ")
        #expect(indentation(after: "    total = 1  # note:") == "    ")
    }

    @Test("An open bracket continues onto an indented line")
    func indentsAfterOpenBracket() {
        #expect(indentation(after: "items = [") == "    ")
        #expect(indentation(after: "    print(") == "        ")
    }

    @Test("Statements that end a block return to the enclosing level")
    func dedentsAfterClosingStatements() {
        #expect(indentation(after: "        return value") == "    ")
        #expect(indentation(after: "    pass") == "")
        #expect(indentation(after: "        raise ValueError()") == "    ")
        #expect(indentation(after: "    break") == "")
        #expect(indentation(after: "    returned = 1") == "    ")
    }

    @Test("Plain text keeps the current line's indentation")
    func plainTextCopiesIndentation() {
        let result = CodeIndentation.newlineIndentation(
            after: "\tnotes {",
            language: .plainText,
            width: 4
        )
        #expect(result == "\t")
    }

    @Test("A soft tab advances to the next tab stop")
    func softTabReachesNextStop() {
        #expect(CodeIndentation.softTab(atColumn: 0, width: 4) == "    ")
        #expect(CodeIndentation.softTab(atColumn: 2, width: 4) == "  ")
        #expect(CodeIndentation.softTab(atColumn: 4, width: 4) == "    ")
    }

    @Test("Delete in leading spaces removes one tab stop")
    func deleteRemovesSoftTab() {
        #expect(CodeIndentation.softTabDeletionLength(lineBeforeCaret: "        ", width: 4) == 4)
        #expect(CodeIndentation.softTabDeletionLength(lineBeforeCaret: "      ", width: 4) == 2)
        #expect(CodeIndentation.softTabDeletionLength(lineBeforeCaret: "    x", width: 4) == nil)
        #expect(CodeIndentation.softTabDeletionLength(lineBeforeCaret: "", width: 4) == nil)
    }

    @Test("Code indents with spaces; prose and Go keep tabs")
    func softTabsForCode() {
        #expect(CodeIndentation.usesSoftTabs(for: .python))
        #expect(CodeIndentation.usesSoftTabs(for: .javascript))
        #expect(!CodeIndentation.usesSoftTabs(for: .go))
        #expect(!CodeIndentation.usesSoftTabs(for: .latex))
        #expect(!CodeIndentation.usesSoftTabs(for: .markdown))
    }

    private func indentation(after line: String) -> String {
        CodeIndentation.newlineIndentation(after: line, language: .python, width: 4)
    }
}

@Suite("Code indentation across languages")
struct BlockIndentationTests {
    @Test("An open brace indents the next line in brace languages")
    func braceOpensBlock() {
        for language: LanguageID in [.javascript, .rust, .c, .java, .swift] {
            #expect(
                CodeIndentation.newlineIndentation(
                    after: "  fn main() {", language: language, width: 2) == "    ",
                "\(language.rawValue)")
        }
    }

    @Test("Go indents with a tab, as gofmt does")
    func goUsesTabs() {
        #expect(!CodeIndentation.usesSoftTabs(for: .go))
        #expect(
            CodeIndentation.newlineIndentation(
                after: "func main() {", language: .go, width: 4) == "\t")
    }

    @Test("Return between brackets puts the closer on its own line")
    func expandsBetweenBrackets() {
        let expansion = CodeIndentation.blockExpansion(
            lineBeforeCaret: "  if (ok) {",
            characterAfterCaret: "}",
            language: .javascript,
            width: 2
        )
        #expect(expansion?.text == "\n    \n  ")
        #expect(expansion?.caretOffset == 5)
        #expect(
            CodeIndentation.blockExpansion(
                lineBeforeCaret: "if (ok) {", characterAfterCaret: "x",
                language: .javascript, width: 2) == nil)
    }

    @Test("Typing a closing brace on a blank line lines it up with its block")
    func closingBraceDedents() {
        #expect(
            CodeIndentation.closingBracketDedent(
                lineBeforeCaret: "        ", typed: "}", language: .c, width: 4) == 4)
        #expect(
            CodeIndentation.closingBracketDedent(
                lineBeforeCaret: "    x", typed: "}", language: .c, width: 4) == nil)
        #expect(
            CodeIndentation.closingBracketDedent(
                lineBeforeCaret: "\t\t", typed: "}", language: .go, width: 4) == 1)
    }

    @Test("Plain text and LaTeX keep copying indentation")
    func proseIsUntouched() {
        #expect(
            CodeIndentation.newlineIndentation(
                after: "  \\begin{itemize}", language: .latex, width: 4) == "  ")
        #expect(!CodeIndentation.usesSoftTabs(for: .plainText))
    }
}
