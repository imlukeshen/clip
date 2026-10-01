import CoreModel
import Foundation

/// A programming-language decision for text pasted into a Markdown document.
public struct MarkdownCodePasteDetection: Sendable, Equatable {
    /// The language used for the inserted fenced code block.
    public let language: LanguageID

    /// Creates a detected-code result.
    public init(language: LanguageID) {
        self.language = language
    }
}

/// A fenced code block and its source ranges inside a Markdown buffer.
public struct MarkdownFencedCodeBlock: Sendable, Equatable {
    /// The range including the opening and closing fences.
    public let range: NSRange
    /// The code-only range between the two fences.
    public let codeRange: NSRange
    /// The declared language, or plain text when the fence has no known label.
    public let language: LanguageID

    /// Creates a fenced-code description.
    public init(range: NSRange, codeRange: NSRange, language: LanguageID) {
        self.range = range
        self.codeRange = codeRange
        self.language = language
    }
}

/// Markdown-aware helpers shared by paste handling and live presentation.
public enum MarkdownEditingIntelligence {
    /// Detects a high-confidence programming-language paste.
    ///
    /// Existing Markdown, prose, LaTeX, and already fenced content are deliberately
    /// rejected. This keeps ordinary notes from unexpectedly turning into code blocks.
    public static func detectCodePaste(in contents: String) -> MarkdownCodePasteDetection? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("```") else { return nil }

        let language = LanguageDetector.detect(path: "", contents: trimmed)
        guard codeLanguages.contains(language) else { return nil }

        let nonemptyLines = trimmed.split(whereSeparator: \Character.isNewline)
        if nonemptyLines.count == 1, !singleLineLanguages.contains(language) {
            return nil
        }
        return MarkdownCodePasteDetection(language: language)
    }

    /// Finds fenced code blocks (backtick or tilde, any length of three or
    /// more) with their per-block languages, by the same rules the block
    /// parser uses. A fence still being typed runs to the end of the text.
    public static func fencedCodeBlocks(in source: String) -> [MarkdownFencedCodeBlock] {
        let text = source as NSString
        return MarkdownFenceScanner.fences(in: source).map { fence in
            let declaredLanguage = language(forFenceLabel: fence.label)
            let language =
                declaredLanguage == .plainText
                ? embeddedLanguage(
                    from: LanguageDetector.detect(
                        path: "",
                        contents: text.substring(with: fence.contentRange)
                    )
                ) : declaredLanguage
            return MarkdownFencedCodeBlock(
                range: fence.range,
                codeRange: fence.contentRange,
                language: language
            )
        }
    }

    /// Returns whether a UTF-16 location is currently inside a fenced code block,
    /// including one whose closing fence has not been typed yet.
    public static func isInsideFencedCode(location: Int, in source: String) -> Bool {
        MarkdownFenceScanner.fences(in: source).contains { fence in
            location > fence.range.location
                && (location < NSMaxRange(fence.range)
                    || (fence.closingMarkerRange == nil && location <= NSMaxRange(fence.range)))
        }
    }

    /// Returns the portable Markdown label for a detected language.
    public static func fenceLabel(for language: LanguageID) -> String {
        return switch language {
        case .plainText: ""
        case .bash: "bash"
        case .cpp: "cpp"
        case .javascript: "javascript"
        case .typescript: "typescript"
        default: language.rawValue
        }
    }

    private static func language(forFenceLabel label: String) -> LanguageID {
        switch label {
        case "", "text", "txt": return .plainText
        case "sh", "shell", "zsh", "bash": return .bash
        case "js", "jsx", "javascript": return .javascript
        case "ts", "tsx", "typescript": return .typescript
        case "py", "python": return .python
        case "c++", "cc", "cpp": return .cpp
        case "yml", "yaml": return .yaml
        case "htm", "html": return .html
        default:
            let candidate = LanguageID(rawValue: label)
            return candidate.hasTreeSitterGrammar ? candidate : .plainText
        }
    }

    private static func embeddedLanguage(from detected: LanguageID) -> LanguageID {
        detected == .markdown ? .plainText : detected
    }

    private static let codeLanguages: Set<LanguageID> = [
        .swift, .javascript, .typescript, .python, .json, .yaml, .toml,
        .html, .css, .rust, .go, .c, .cpp, .java, .sql, .bash, .xml,
    ]

    /// These grammars have unambiguous single-line forms in the detector.
    private static let singleLineLanguages: Set<LanguageID> = [
        .json, .html, .sql, .xml,
    ]
}

/// Produces language-aware syntax roles for fenced code without executing it.
public actor MarkdownFencedCodeHighlighter {
    private var highlighters: [LanguageID: SyntaxHighlighter] = [:]
    private var cachedSource = ""
    private var cachedBlocks: [MarkdownFencedCodeBlock] = []

    /// Creates an isolated Markdown fenced-code highlighting session.
    public init() {}

    /// Highlights visible fenced code and translates its token ranges back into
    /// coordinates for the complete Markdown document.
    public func highlights(in source: String, visibleRange: NSRange) async -> [SyntaxToken] {
        let sourceRange = NSRange(location: 0, length: (source as NSString).length)
        let visible = NSIntersectionRange(visibleRange, sourceRange)
        let blocks: [MarkdownFencedCodeBlock]
        if source == cachedSource {
            blocks = cachedBlocks
        } else {
            blocks = MarkdownEditingIntelligence.fencedCodeBlocks(in: source)
            cachedSource = source
            cachedBlocks = blocks
        }
        var tokens: [SyntaxToken] = []
        for block in blocks {
            guard block.language != .plainText,
                NSIntersectionRange(block.codeRange, visible).length > 0
            else { continue }
            let code = (source as NSString).substring(with: block.codeRange)
            let localVisible = NSRange(location: 0, length: (code as NSString).length)
            let highlighter = highlighters[block.language] ?? SyntaxHighlighter()
            highlighters[block.language] = highlighter
            let result = await highlighter.highlights(
                in: code,
                language: block.language,
                visibleRange: localVisible
            )
            tokens.append(
                contentsOf: result.tokens.map { token in
                    SyntaxToken(
                        range: NSRange(
                            location: block.codeRange.location + token.range.location,
                            length: token.range.length
                        ),
                        kind: token.kind
                    )
                }
            )
        }
        return tokens
    }
}
