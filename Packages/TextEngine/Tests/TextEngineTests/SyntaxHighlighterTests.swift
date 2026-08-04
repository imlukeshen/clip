import CoreModel
import Foundation
import Testing

@testable import TextEngine

@Test func everyBundledLanguageUsesItsTreeSitterGrammar() async {
    let highlighter = SyntaxHighlighter()
    for language in LanguageID.treeSitterGrammars {
        let source = representativeSource(for: language)
        let result = await highlighter.highlights(
            in: source,
            language: language,
            visibleRange: NSRange(location: 0, length: (source as NSString).length)
        )
        #expect(result.quality == .treeSitter, "Missing grammar for \(language.rawValue)")
    }
}

@Test func typescriptHighlightingProducesSemanticRoles() async {
    let source = """
        // One comment
        const title: string = "Clip"
        function count(items: number[]): number { return items.length + 42 }
        """
    let result = await SyntaxHighlighter().highlights(
        in: source,
        language: .typescript,
        visibleRange: NSRange(location: 0, length: (source as NSString).length)
    )

    #expect(result.quality == .treeSitter)
    #expect(result.tokens.contains { $0.kind == .comment })
    #expect(result.tokens.contains { $0.kind == .string })
    #expect(result.tokens.contains { $0.kind == .number })
    #expect(result.tokens.contains { $0.kind == .keyword })
}

@Test func highlightingIsBoundedToViewportAndTwoHundredLineMargin() async {
    let source = (0..<1_000).map { "let value\($0) = \($0)\n" }.joined()
    let text = source as NSString
    let visibleLocation = text.range(of: "let value500").location
    let result = await SyntaxHighlighter().highlights(
        in: source,
        language: .swift,
        visibleRange: NSRange(location: visibleLocation, length: 12)
    )

    #expect(result.quality == .treeSitter)
    #expect(result.styledRange.location > 0)
    #expect(NSMaxRange(result.styledRange) < text.length)
    #expect(
        result.tokens.allSatisfy { NSIntersectionRange($0.range, result.styledRange).length > 0 })
}

@Test func incrementalEditUpdatesTheExistingParseSession() async {
    let highlighter = SyntaxHighlighter()
    let original = "const answer = 41;"
    _ = await highlighter.highlights(
        in: original,
        language: .typescript,
        visibleRange: NSRange(location: 0, length: (original as NSString).length)
    )
    let current = "const answer = 42;"
    let result = await highlighter.highlights(
        in: current,
        language: .typescript,
        visibleRange: NSRange(location: 0, length: (current as NSString).length),
        edit: SyntaxEdit(
            previousRange: NSRange(location: 16, length: 1),
            currentRange: NSRange(location: 16, length: 1)
        )
    )

    #expect(result.quality == .treeSitter)
    #expect(
        result.tokens.contains { token in
            token.kind == .number && (current as NSString).substring(with: token.range) == "42"
        })
}

@Test func unsupportedLanguagesUseBoundedRegexAndPlainTextStaysPlain() async {
    let highlighter = SyntaxHighlighter()
    let source = "class Clip # comment\nvalue = 42"
    let regex = await highlighter.highlights(
        in: source,
        language: LanguageID(rawValue: "ruby"),
        visibleRange: NSRange(location: 0, length: (source as NSString).length)
    )
    let plain = await highlighter.highlights(
        in: source,
        language: .plainText,
        visibleRange: NSRange(location: 0, length: (source as NSString).length)
    )

    #expect(regex.quality == .regex)
    #expect(!regex.tokens.isEmpty)
    #expect(plain.quality == .plain)
    #expect(plain.tokens.isEmpty)
}

@Test func twoMegabyteTypescriptBufferHighlightsWithinInteractiveBudget() async {
    let line = "const clipValue: number = 42; // buffered syntax line\n"
    let repetitions = 2_000_000 / line.utf8.count + 1
    let source = String(repeating: line, count: repetitions)
    let clock = ContinuousClock()
    let start = clock.now
    let result = await SyntaxHighlighter().highlights(
        in: source,
        language: .typescript,
        visibleRange: NSRange(location: 0, length: 2_000)
    )
    let duration = start.duration(to: clock.now)

    #expect(result.quality == .treeSitter)
    #if DEBUG
        #expect(duration < .seconds(2))
    #else
        #expect(duration < .milliseconds(200))
    #endif
    #expect(result.styledRange.length < (source as NSString).length)
}

private func representativeSource(for language: LanguageID) -> String {
    switch language {
    case .markdown: "# Clip\n\n**Fast** editing."
    case .latex: "\\documentclass{article}\n\\begin{document}Clip\\end{document}"
    case .swift: "struct Clip { let count = 42 }"
    case .javascript: "const clip = () => 'ready';"
    case .typescript: "const clip: string = 'ready';"
    case .python: "def clip():\n    return 42"
    case .json: "{\"clip\": true}"
    case .yaml: "clip:\n  ready: true"
    case .toml: "[clip]\nready = true"
    case .html: "<main>Clip</main>"
    case .css: ".clip { color: white; }"
    case .rust: "fn clip() -> i32 { 42 }"
    case .go: "package main\nfunc clip() int { return 42 }"
    case .c: "int clip(void) { return 42; }"
    case .cpp: "class Clip { public: int count = 42; };"
    case .java: "class Clip { int count = 42; }"
    case .sql: "SELECT title FROM clips WHERE id = 42;"
    case .bash: "#!/bin/bash\necho \"Clip\""
    case .xml: "<?xml version=\"1.0\"?><clip ready=\"true\"/>"
    default: "Clip"
    }
}
