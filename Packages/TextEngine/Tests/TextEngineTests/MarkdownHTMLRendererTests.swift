import Foundation
import Testing

@testable import TextEngine

@Test func markdownRendererSupportsGFMFootnotesMathAndHighlightedFences() {
    let source = """
        # Clip notes

        | Item | Ready |
        | --- | ---: |
        | Preview | Yes |

        - [x] Offline
        - [ ] Export

        ~~old~~ Visit https://example.com and use $x^2$.[^note]

        ```swift
        let answer = 42 // highlighted
        ```

        $$
        E = mc^2
        $$

        [^note]: A rendered **footnote**.
        """

    let result = MarkdownHTMLRenderer.render(source)

    #expect(result.html.contains("<table>"))
    #expect(result.html.contains("type=\"checkbox\" disabled checked"))
    #expect(result.html.contains("<del>old</del>"))
    #expect(result.html.contains("href=\"https://example.com\""))
    #expect(result.html.contains("syntax-keyword"))
    #expect(result.html.contains("syntax-number"))
    #expect(result.html.contains("class=\"math"))
    #expect(result.html.contains("E = mc^2"))
    #expect(result.html.contains("class=\"footnotes\""))
    #expect(result.html.contains("A rendered <strong>footnote</strong>"))
    #expect(result.html.contains("katex.render"))
    #expect(result.html.contains("data:font/woff2;base64,"))
    #expect(result.sourceBlockLines.count >= 6)
}

@Test func documentHTMLAndRemoteImagesCannotExecuteOrLoad() {
    let source = """
        <script>window.clipWasCompromised = true</script>
        <img src="https://tracking.example/pixel.png">

        ![Remote](https://example.com/photo.png)

        [unsafe](javascript:alert(1))
        """
    let result = MarkdownHTMLRenderer.render(source)

    #expect(!result.html.contains("clipWasCompromised"))
    #expect(!result.html.contains("tracking.example"))
    #expect(!result.html.contains("example.com/photo.png"))
    #expect(!result.html.contains("javascript:alert"))
    #expect(result.blockedResourceCount == 2)
    #expect(result.html.contains("Remote or unsafe image blocked"))
    #expect(result.html.contains("default-src 'none'"))
    #expect(result.html.contains("connect-src 'none'"))
}

@Test func previewImagesUseScopedSchemeAndTraversalIsRejected() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("outside-\(UUID().uuidString).png")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let image = root.appendingPathComponent("diagram.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outside)

    let preview = MarkdownHTMLRenderer.render("![Diagram](diagram.png)")
    #expect(preview.html.contains("clip-local://asset/diagram.png"))
    #expect(MarkdownLocalResourceResolver.resolve("diagram.png", below: root) == image)
    #expect(
        MarkdownLocalResourceResolver.resolve("../\(outside.lastPathComponent)", below: root) == nil
    )
    #expect(MarkdownLocalResourceResolver.resolve("/etc/passwd", below: root) == nil)
    #expect(MarkdownLocalResourceResolver.resolve("notes.svg", below: root) == nil)
}

@Test func exportedMarkdownEmbedsLocalImagesAndBlocksMissingFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0x89, 0x50, 0x4E, 0x47]).write(
        to: root.appendingPathComponent("diagram.png")
    )

    let result = MarkdownHTMLRenderer.render(
        "![Diagram](diagram.png) ![Missing](missing.png)",
        destination: .export(baseDirectory: root)
    )

    #expect(result.html.contains("data:image/png;base64,"))
    #expect(result.blockedResourceCount == 1)
}
