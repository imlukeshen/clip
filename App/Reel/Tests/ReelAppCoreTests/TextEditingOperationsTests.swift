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
}
