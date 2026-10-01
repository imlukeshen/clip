import Foundation
import Testing

@testable import TextEngine

@Test func mermaidBlocksAreFoundWithTheirClosingFence() {
    let markdown = """
        # Flow

        ```mermaid
        flowchart TD
            A --> B
        ```

        ```swift
        let x = 1
        ```
        """
    let diagrams = MermaidDiagram.diagrams(in: markdown)
    #expect(diagrams.count == 1)
    #expect(diagrams.first?.source == "flowchart TD\n    A --> B")
    let closing = try? #require(diagrams.first?.closingFenceRange)
    #expect(closing.map { (markdown as NSString).substring(with: $0) } == "```")
}

@Test func theMermaidLibraryIsBundled() {
    #expect(MermaidAssets.javaScript.contains("globalThis[\"mermaid\"]"))
}

@Test func exportedHTMLRendersMermaidOnlyWhenThereIsADiagram() throws {
    let withDiagram = MarkdownHTMLRenderer.render(
        "```mermaid\nflowchart TD\n  A --> B\n```\n",
        destination: .export(baseDirectory: nil)
    ).html
    #expect(withDiagram.contains(#"<pre class="mermaid">flowchart TD"#))
    #expect(withDiagram.contains("A --&gt; B"))
    #expect(withDiagram.contains("mermaid.run("))

    let plain = MarkdownHTMLRenderer.render("# Title\n", destination: .export(baseDirectory: nil))
        .html
    #expect(!plain.contains("mermaid.run("))
}

@Test func tildeAndLongerFencesCountEverywhereTheBlockParserCountsThem() {
    let markdown = """
        ~~~mermaid
        flowchart LR
          A --> B
        ~~~

        ````python
        print("```")
        ````
        """
    #expect(MermaidDiagram.diagrams(in: markdown).map(\.source) == ["flowchart LR\n  A --> B"])

    let blocks = MarkdownEditingIntelligence.fencedCodeBlocks(in: markdown)
    #expect(blocks.count == 2)
    #expect(blocks.last?.language == .python)
    // The inner ``` is code, not a closing fence.
    let inner = (markdown as NSString).range(of: "print").location
    #expect(MarkdownEditingIntelligence.isInsideFencedCode(location: inner, in: markdown))
    let tildeBody = (markdown as NSString).range(of: "A --> B").location
    #expect(MarkdownEditingIntelligence.isInsideFencedCode(location: tildeBody, in: markdown))
}

@Test func aFenceStillBeingTypedCountsAsCode() {
    let markdown = "Intro\n```swift\nlet x = 1"
    let end = (markdown as NSString).length
    #expect(MarkdownEditingIntelligence.isInsideFencedCode(location: end, in: markdown))
    #expect(!MarkdownEditingIntelligence.isInsideFencedCode(location: 2, in: markdown))
    #expect(MermaidDiagram.diagrams(in: "```mermaid\nflowchart TD\n  A --> B").isEmpty)
}

@Test func inlineCodeWithBackticksIsNotAFence() {
    let markdown = "``` `code` ```\n# Heading\n"
    #expect(MarkdownEditingIntelligence.fencedCodeBlocks(in: markdown).isEmpty)
    let document = MarkdownBlockDocumentEngine.reconcile(source: markdown)
    #expect(!document.blocks.contains { if case .fencedCode = $0.kind { true } else { false } })
    #expect(document.blocks.contains { $0.kind == .heading(level: 1) })
}

@Test func crlfDiagramsKeepTheirLastCharacter() {
    let markdown = "```mermaid\r\ngraph TD\r\n  A-->B\r\n```\r\n"
    #expect(MermaidDiagram.diagrams(in: markdown).map(\.source) == ["graph TD\r\n  A-->B"])
}
