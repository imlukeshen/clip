import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Text editing operations")
struct TextEditingOperationsTests {
    @Test("Comment toggling preserves line endings and reverses exactly")
    func commentRoundTrip() {
        let source = "let first = 1\r\nlet second = 2\r\n"
        let selection = NSRange(location: 0, length: (source as NSString).length)

        let commented = TextEditingOperations.toggleComment(
            in: source,
            selectedRange: selection,
            prefix: "//"
        )
        #expect(commented.text == "// let first = 1\r\n// let second = 2\r\n")

        let restored = TextEditingOperations.toggleComment(
            in: commented.text,
            selectedRange: commented.selectedRange,
            prefix: "//"
        )
        #expect(restored.text == source)
    }

    @Test("Markup comments include and remove their closing delimiter")
    func markupCommentRoundTrip() {
        let source = "<section>Clip</section>\n"
        let commented = TextEditingOperations.toggleComment(
            in: source,
            selectedRange: NSRange(location: 0, length: source.utf16.count),
            prefix: "<!--",
            suffix: "-->"
        )
        #expect(commented.text == "<!-- <section>Clip</section> -->\n")
        let restored = TextEditingOperations.toggleComment(
            in: commented.text,
            selectedRange: commented.selectedRange,
            prefix: "<!--",
            suffix: "-->"
        )
        #expect(restored.text == source)
    }

    @Test("Indent and outdent operate on every selected line")
    func indentation() {
        let source = "first\n  second\n"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        let indented = TextEditingOperations.indent(
            in: source,
            selectedRange: selection,
            width: 2
        )
        #expect(indented.text == "  first\n    second\n")

        let restored = TextEditingOperations.outdent(
            in: indented.text,
            selectedRange: indented.selectedRange,
            width: 2
        )
        #expect(restored.text == source)
    }

    @Test("Duplicate and move line keep the caret with edited content")
    func lineMovement() {
        let source = "alpha\nbeta\ngamma\n"
        let caret = NSRange(location: 7, length: 0)
        let duplicated = TextEditingOperations.duplicateLine(
            in: source,
            selectedRange: caret
        )
        #expect(duplicated.text == "alpha\nbeta\nbeta\ngamma\n")

        let moved = TextEditingOperations.moveLine(
            in: source,
            selectedRange: caret,
            direction: .up
        )
        #expect(moved.text == "beta\nalpha\ngamma\n")
        #expect(moved.selectedRange.location < caret.location)
    }

    @Test("Moving lines preserves the separator when the file has no final newline")
    func lineMovementWithoutFinalNewline() {
        let source = "alpha\nbeta"
        let betaCaret = NSRange(location: 7, length: 0)
        let movedUp = TextEditingOperations.moveLine(
            in: source,
            selectedRange: betaCaret,
            direction: .up
        )
        #expect(movedUp.text == "beta\nalpha")

        let alphaCaret = NSRange(location: 1, length: 0)
        let movedDown = TextEditingOperations.moveLine(
            in: source,
            selectedRange: alphaCaret,
            direction: .down
        )
        #expect(movedDown.text == "beta\nalpha")
        #expect(movedDown.selectedRange.location == 6)
    }

    @Test("Save cleanup removes trailing spaces without changing terminators")
    func trailingWhitespace() {
        let source = "alpha  \r\nbeta\t\r\nfinal  "
        #expect(
            TextEditingOperations.trimmingTrailingWhitespace(in: source)
                == "alpha\r\nbeta\r\nfinal"
        )
    }

    @Test("Line ending normalization handles mixed CRLF, LF, and CR")
    func lineEndingNormalization() {
        let source = "one\r\ntwo\nthree\rfour"

        #expect(
            TextEditingOperations.normalizingLineEndings(in: source, to: .lf)
                == "one\ntwo\nthree\nfour"
        )
        #expect(
            TextEditingOperations.normalizingLineEndings(in: source, to: .crlf)
                == "one\r\ntwo\r\nthree\r\nfour"
        )
        #expect(
            TextEditingOperations.normalizingLineEndings(in: source, to: .cr)
                == "one\rtwo\rthree\rfour"
        )
        #expect(TextEditingOperations.normalizingLineEndings(in: source, to: .mixed) == source)
    }

    @Test("Find supports literal text, regular expressions, and invalid patterns")
    func findPatterns() throws {
        let source = "Clip clip clop 123 456"
        let literal = try TextEditingOperations.matchingRanges(
            in: source,
            query: "clip",
            usesRegularExpression: false
        )
        let numbers = try TextEditingOperations.matchingRanges(
            in: source,
            query: "\\d+",
            usesRegularExpression: true
        )

        #expect(literal.count == 2)
        #expect(numbers.map(\.length) == [3, 3])
        #expect {
            try TextEditingOperations.matchingRanges(
                in: source,
                query: "[",
                usesRegularExpression: true
            )
        } throws: { $0 is TextEditingOperations.InvalidSearchPattern }
    }

    @Test("Bracket matching follows nesting from either side of the caret")
    func bracketMatching() {
        let source = "call(one[2], { three })"
        #expect(
            TextEditingOperations.matchingBracketRanges(in: source, caretLocation: 4)
                == [NSRange(location: 4, length: 1), NSRange(location: 22, length: 1)]
        )
        #expect(
            TextEditingOperations.matchingBracketRanges(in: source, caretLocation: 11)
                == [NSRange(location: 8, length: 1), NSRange(location: 10, length: 1)]
        )
        #expect(
            TextEditingOperations.matchingBracketRanges(in: "(unclosed", caretLocation: 0)
                .isEmpty
        )
    }

    @Test("Markdown inline formatting wraps, unwraps, and positions the selection")
    func markdownInlineFormatting() {
        let source = "Make this clear"
        let selection = NSRange(location: 5, length: 4)
        let bold = MarkdownFormattingOperations.apply(
            .bold,
            to: source,
            selectedRange: selection
        )
        #expect(bold.text == "Make **this** clear")
        #expect(bold.selectedRange == NSRange(location: 7, length: 4))

        let restored = MarkdownFormattingOperations.apply(
            .bold,
            to: bold.text,
            selectedRange: bold.selectedRange
        )
        #expect(restored.text == source)
        #expect(restored.selectedRange == selection)

        let placeholder = MarkdownFormattingOperations.apply(
            .italic,
            to: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(placeholder.text == "_italic text_")
        #expect(placeholder.selectedRange == NSRange(location: 1, length: 11))
    }

    @Test("Markdown block styles transform selected lines and toggle cleanly")
    func markdownBlockFormatting() {
        let source = "First\nSecond\n"
        let all = NSRange(location: 0, length: (source as NSString).length)
        let checklist = MarkdownFormattingOperations.apply(
            .checklist,
            to: source,
            selectedRange: all
        )
        #expect(checklist.text == "- [ ] First\n- [ ] Second\n")

        let restored = MarkdownFormattingOperations.apply(
            .checklist,
            to: checklist.text,
            selectedRange: checklist.selectedRange
        )
        #expect(restored.text == source)

        let heading = MarkdownFormattingOperations.apply(
            .heading2,
            to: "# Existing heading\n",
            selectedRange: NSRange(location: 3, length: 0)
        )
        #expect(heading.text == "## Existing heading\n")
        let body = MarkdownFormattingOperations.apply(
            .body,
            to: heading.text,
            selectedRange: heading.selectedRange
        )
        #expect(body.text == "Existing heading\n")
    }

    @Test("Markdown link and block insertion select the next editable content")
    func markdownInsertions() {
        let link = MarkdownFormattingOperations.apply(
            .link,
            to: "Clip",
            selectedRange: NSRange(location: 0, length: 4)
        )
        #expect(link.text == "[Clip](https://)")
        #expect((link.text as NSString).substring(with: link.selectedRange) == "https://")

        let block = MarkdownFormattingOperations.apply(
            .codeBlock,
            to: "sample",
            selectedRange: NSRange(location: 0, length: 6)
        )
        #expect(block.text == "```\nsample\n```")
        #expect((block.text as NSString).substring(with: block.selectedRange) == "sample")

        let detectedBlock = MarkdownFormattingOperations.insertingCodeBlock(
            contents: "def render():\n    return True",
            language: .python,
            into: "Before\n",
            selectedRange: NSRange(location: 7, length: 0)
        )
        #expect(detectedBlock.text == "Before\n```python\ndef render():\n    return True\n```")
    }

    @Test("Markdown rich block insertions keep their next field editable")
    func markdownRichBlockInsertions() {
        let image = MarkdownFormattingOperations.apply(
            .image,
            to: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(image.text == "![Image description](image.png)")
        #expect((image.text as NSString).substring(with: image.selectedRange) == "image.png")

        let table = MarkdownFormattingOperations.apply(
            .table,
            to: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(table.text.contains("| --- | --- |"))
        #expect((table.text as NSString).substring(with: table.selectedRange) == "Column 1")

        let footnote = MarkdownFormattingOperations.apply(
            .footnote,
            to: "Existing[^1]\n\n[^1]: First",
            selectedRange: NSRange(location: 8, length: 0)
        )
        #expect(footnote.text.contains("[^2]: Footnote text"))
        #expect(
            (footnote.text as NSString).substring(with: footnote.selectedRange) == "Footnote text")

        let math = MarkdownFormattingOperations.apply(
            .mathBlock,
            to: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(math.text == "$$\nE = mc^2\n$$")
        #expect((math.text as NSString).substring(with: math.selectedRange) == "E = mc^2")
    }
}
