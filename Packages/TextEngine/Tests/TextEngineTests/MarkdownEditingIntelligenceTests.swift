import CoreModel
import Foundation
import Testing

@testable import TextEngine

@Test func markdownCodePasteDetectionIsConservativeAndLanguageAware() {
    #expect(
        MarkdownEditingIntelligence.detectCodePaste(
            in:
                "import SwiftUI\n\nstruct Card: View {\n    var body: some View { Text(\"Clip\") }\n}"
        )?.language == .swift
    )
    #expect(
        MarkdownEditingIntelligence.detectCodePaste(
            in: "def render_clip():\n    return True"
        )?.language == .python
    )
    #expect(
        MarkdownEditingIntelligence.detectCodePaste(in: "{\"ready\": true}")?.language == .json
    )
    #expect(MarkdownEditingIntelligence.detectCodePaste(in: "A normal sentence.") == nil)
    #expect(MarkdownEditingIntelligence.detectCodePaste(in: "- [ ] Ship the editor") == nil)
    #expect(MarkdownEditingIntelligence.detectCodePaste(in: "```swift\nlet x = 1\n```") == nil)
    #expect(MarkdownEditingIntelligence.detectCodePaste(in: "console.log('Clip')") == nil)
}

@Test func markdownFenceScanningDetectsLanguagePerBlock() {
    let source = """
        Intro

        ```swift
        let answer = 42
        ```

        ```python
        print("Clip")
        ```
        """
    let blocks = MarkdownEditingIntelligence.fencedCodeBlocks(in: source)
    #expect(blocks.map(\.language) == [.swift, .python])
    #expect((source as NSString).substring(with: blocks[0].codeRange).contains("let answer"))
    #expect(
        MarkdownEditingIntelligence.isInsideFencedCode(
            location: blocks[1].codeRange.location,
            in: source
        )
    )

    let unlabeled = MarkdownEditingIntelligence.fencedCodeBlocks(
        in: "```\ndef inferred():\n    return True\n```"
    )
    #expect(unlabeled.first?.language == .python)
    #expect(
        MarkdownEditingIntelligence.isInsideFencedCode(
            location: 15,
            in: "```swift\nlet unfinished = true"
        )
    )
}

@Test func fencedCodeHighlighterReturnsDocumentRanges() async {
    let source = "Before\n\n```swift\nlet answer = 42\n```\n"
    let highlighter = MarkdownFencedCodeHighlighter()
    let tokens = await highlighter.highlights(
        in: source,
        visibleRange: NSRange(location: 0, length: (source as NSString).length)
    )
    let codeRange = MarkdownEditingIntelligence.fencedCodeBlocks(in: source)[0].codeRange
    #expect(!tokens.isEmpty)
    #expect(
        tokens.allSatisfy { NSIntersectionRange($0.range, codeRange).length == $0.range.length })
}
