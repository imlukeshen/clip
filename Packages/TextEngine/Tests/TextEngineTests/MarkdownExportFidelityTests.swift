import Foundation
import Testing

@testable import TextEngine

@Suite("Markdown export fidelity")
struct MarkdownExportFidelityTests {
    /// The rendered document body, without the page's styles and scripts.
    private func html(_ markdown: String) -> String {
        let page = MarkdownHTMLRenderer.render(markdown, destination: .export(baseDirectory: nil))
            .html
        guard let start = page.range(of: "<main>"), let end = page.range(of: "</main>") else {
            return page
        }
        return String(page[start.lowerBound..<end.upperBound])
    }

    @Test("Prices are text, and real inline math is still math")
    func dollarsAreNotMath() {
        let page = html("It costs $5 and $10 per seat, and $x^2$ grows.\n")
        #expect(page.contains("It costs $5 and $10 per seat"))
        #expect(page.contains(#"data-tex="x^2""#))
    }

    @Test("Dollar signs in indented and nested code stay as written")
    func codeKeepsDollars() {
        let page = html(
            "Run:\n\n    echo $HOME and $PATH\n\n- step\n\n  ```bash\n  echo $USER $SHELL\n  ```\n")
        #expect(page.contains("echo $HOME and $PATH"))
        #expect(page.contains("echo $USER $SHELL"))
        #expect(!page.contains("CLIPMATH"))
    }

    @Test("Footnote syntax inside a code block is code, not a footnote")
    func footnotesInCodeAreCode() {
        let page = html("Example:\n\n```markdown\nText[^1]\n\n[^1]: the note\n```\n")
        #expect(page.contains("<pre><code"))
        #expect(page.contains("]: the note"))
        #expect(!page.contains(#"class="footnotes""#))
    }

    @Test("The editor does not style prices as math either")
    func editorDollarsAreNotMath() {
        let document = MarkdownBlockDocumentEngine.reconcile(
            source: "It costs $5 and $10.\nArea $a^2$.\n")
        let mathSpans = document.blocks.flatMap(\.inlineSpans).filter { $0.kind == .math }
        #expect(mathSpans.count == 1)
    }
}
