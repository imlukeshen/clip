import AppKit
import Testing

@testable import Reel

@MainActor
@Suite("Return keeps the file's line ending")
struct CodeTextViewLineEndingTests {
    @Test("Return in a CRLF file inserts CRLF")
    func returnInsertsCRLF() {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.string = "a\r\nb"
        textView.lineBreak = "\r\n"
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "a\r\nb\r\n")
    }

    @Test("Return in an LF file still inserts LF")
    func returnInsertsLF() {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.string = "a\nb"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "a\nb\n")
    }
}
