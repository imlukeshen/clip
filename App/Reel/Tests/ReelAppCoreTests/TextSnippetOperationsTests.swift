import AppKit
import CoreModel
import Foundation
import Testing
import TextEngine

@testable import ReelAppCore

@Suite("Text snippet operations")
struct TextSnippetOperationsTests {
    @Test("Line-numbered and annotated copies preserve source context")
    func contextualCopies() throws {
        let source = "zero\r\none\r\ntwo"
        let range = try #require((source as NSString).range(of: "one\r\ntwo").nonempty)

        #expect(
            TextSnippetOperations.copyWithLineNumbers(in: source, selectedRange: range)
                == "2 │ one\n3 │ two"
        )
        #expect(
            TextSnippetOperations.annotatedSelection(
                in: source,
                selectedRange: range,
                fileName: "Sources/file.swift"
            ) == "Sources/file.swift:2–3\none\r\ntwo"
        )
    }

    @Test("Code fences include the language and outgrow embedded delimiters")
    func safeCodeFence() throws {
        let source = "let marker = \"```\""
        let range = NSRange(location: 0, length: (source as NSString).length)
        let result = try #require(
            TextSnippetOperations.wrappingSelectionInCodeFence(
                in: source,
                selectedRange: range,
                language: .swift
            )
        )

        #expect(result.text.hasPrefix("````swift\n"))
        #expect(result.text.hasSuffix("\n````"))
        #expect((result.text as NSString).substring(with: result.selectedRange) == source)
    }

    @MainActor
    @Test("Rich text and standalone HTML retain color without executable markup")
    func richAndHTMLExport() throws {
        let source = "<script>alert('x')</script>\nlet value = 1"
        let attributed = TextSnippetOperations.attributedString(
            source: source,
            tokens: [
                SyntaxToken(
                    range: (source as NSString).range(of: "let"),
                    kind: .keyword
                )
            ]
        )

        #expect(
            TextSnippetOperations.richTextData(
                from: attributed,
                backgroundColor: .white
            )?.isEmpty == false
        )
        let html = TextSnippetOperations.standaloneHTML(
            title: "<unsafe>",
            attributedString: attributed
        )
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("&lt;script&gt;alert"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("<title>&lt;unsafe&gt;</title>"))
        #expect(html.contains("color:#"))
        #expect(!html.contains("http://"))
        #expect(!html.contains("https://"))
    }
}

extension NSRange {
    fileprivate var nonempty: NSRange? {
        location == NSNotFound || length == 0 ? nil : self
    }
}
