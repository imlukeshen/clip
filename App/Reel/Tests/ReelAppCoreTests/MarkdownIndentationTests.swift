import Foundation
import Testing

@testable import ReelAppCore

@Suite("Markdown Tab and Shift-Tab")
struct MarkdownIndentationTests {
    /// `|` marks the caret in these fixtures.
    private func caret(_ marked: String) -> (String, NSRange) {
        let location = (marked as NSString).range(of: "|").location
        return (
            marked.replacingOccurrences(of: "|", with: ""),
            NSRange(location: location, length: 0)
        )
    }

    private func marked(_ result: TextEditResult) -> String {
        #expect(result.selectedRange.length == 0)
        return (result.text as NSString).replacingCharacters(
            in: NSRange(location: result.selectedRange.location, length: 0),
            with: "|"
        )
    }

    @Test("Tab nests a bullet under the one above and keeps the caret in place")
    func tabNestsBullet() {
        let (text, selection) = caret("- one\n- tw|o\n")
        let result = MarkdownIndentation.tab(in: text, selectedRange: selection, width: 4)
        #expect(marked(result) == "- one\n  - tw|o\n")
    }

    @Test("A numbered item nests under its parent's text, not four spaces in")
    func tabNestsNumbered() {
        let (text, selection) = caret("1. one\n2. |two\n")
        let result = MarkdownIndentation.tab(in: text, selectedRange: selection, width: 4)
        #expect(marked(result) == "1. one\n   2. |two\n")
    }

    @Test("Tab again nests a second level under the new sibling")
    func tabNestsTwice() {
        let (text, selection) = caret("- one\n  - two\n  - thr|ee\n")
        let result = MarkdownIndentation.tab(in: text, selectedRange: selection, width: 4)
        #expect(marked(result) == "- one\n  - two\n    - thr|ee\n")
    }

    @Test("The first item has nothing to nest under, so Tab leaves it alone")
    func tabFirstItemIsNoOp() {
        let (text, selection) = caret("Intro\n\n- fir|st\n")
        let result = MarkdownIndentation.tab(in: text, selectedRange: selection, width: 4)
        #expect(marked(result) == "Intro\n\n- fir|st\n")
    }

    @Test("Shift-Tab steps a nested item back out to its parent's level")
    func backtabOutdents() {
        let (text, selection) = caret("- one\n  - two\n    - thr|ee\n")
        let result = MarkdownIndentation.backtab(in: text, selectedRange: selection, width: 4)
        #expect(marked(result) == "- one\n  - two\n  - thr|ee\n")
    }

    @Test("Tab in a paragraph inserts spaces at the caret instead of making a code block")
    func tabInParagraph() {
        let (text, selection) = caret("Goal:|ship it\n")
        let result = MarkdownIndentation.tab(in: text, selectedRange: selection, width: 4)
        #expect(marked(result) == "Goal:   |ship it\n")
    }

    @Test("Tab inside a fenced code block is a soft tab at the caret")
    func tabInFence() {
        let (text, selection) = caret("```python\ndef f():\n|pass\n```\n")
        let result = MarkdownIndentation.tab(in: text, selectedRange: selection, width: 4)
        #expect(marked(result) == "```python\ndef f():\n    |pass\n```\n")
    }

    @Test("A list-looking line inside a fence is code, not a list")
    func listInsideFenceIsCode() {
        let (text, selection) = caret("```\n- one\n- |two\n```\n")
        let result = MarkdownIndentation.tab(in: text, selectedRange: selection, width: 4)
        #expect(marked(result) == "```\n- one\n-   |two\n```\n")
    }

    @Test("Tab over several items nests them together and keeps them selected")
    func tabSelection() {
        let text = "- one\n- two\n- three\n"
        let start = (text as NSString).range(of: "- two").location
        let selection = NSRange(location: start, length: (text as NSString).length - start)
        let result = MarkdownIndentation.tab(in: text, selectedRange: selection, width: 4)
        #expect(result.text == "- one\n  - two\n  - three\n")
        #expect(
            (result.text as NSString).substring(with: result.selectedRange)
                == "  - two\n  - three"
        )
    }

    @Test("Return on an empty nested item steps it out a level")
    func returnOnEmptyNestedItem() {
        let (text, selection) = caret("- one\n  - |\n")
        let result = MarkdownIndentation.outdentingEmptyNestedItem(
            in: text,
            caret: selection.location
        )
        #expect(result.map(marked) == "- one\n- |\n")
        #expect(MarkdownIndentation.outdentingEmptyNestedItem(in: "- |", caret: 2) == nil)
    }
}

@Suite("Markdown inserts for writing specs")
struct MarkdownSpecInsertTests {
    @Test("A code block carries the chosen language and selects its placeholder")
    func codeBlockInLanguage() {
        let result = MarkdownFormattingOperations.insertingCodeBlock(
            languageLabel: "python",
            into: "Intro\n",
            selectedRange: NSRange(location: 6, length: 0)
        )
        #expect(result.text == "Intro\n```python\ncode\n```")
        #expect((result.text as NSString).substring(with: result.selectedRange) == "code")
    }

    @Test("A Mermaid block starts with a diagram that renders")
    func mermaidBlock() {
        let result = MarkdownFormattingOperations.insertingCodeBlock(
            languageLabel: "mermaid",
            into: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(result.text.hasPrefix("```mermaid\nflowchart TD\n"))
        #expect(result.text.hasSuffix("\n```"))
    }

    @Test("Selected text becomes the code block's contents")
    func selectionBecomesContents() {
        let result = MarkdownFormattingOperations.insertingCodeBlock(
            languageLabel: "sql",
            into: "select 1",
            selectedRange: NSRange(location: 0, length: 8)
        )
        #expect(result.text == "```sql\nselect 1\n```")
    }

    @Test("The PRD outline selects the product name so typing replaces it")
    func prdOutline() {
        let result = MarkdownFormattingOperations.insertingPRDOutline(
            into: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(result.text.hasPrefix("# Product name\n"))
        for heading in ["## Problem", "## Goals", "## Non-goals", "## Requirements", "```mermaid"] {
            #expect(result.text.contains(heading))
        }
        #expect(
            (result.text as NSString).substring(with: result.selectedRange) == "Product name"
        )
    }
}
