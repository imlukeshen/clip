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
