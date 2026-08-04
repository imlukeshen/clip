import CoreModel
import Foundation

enum RegexSyntaxHighlighter {
    private static let maximumTokenCount = 24_000

    static func tokens(
        in source: String,
        language: LanguageID,
        range: NSRange
    ) -> [SyntaxToken] {
        guard language != .plainText, range.length > 0 else { return [] }
        var tokens: [SyntaxToken] = []
        let specifications: [(String, NSRegularExpression.Options, SyntaxTokenKind)] = [
            (#"//[^\r\n]*|#[^\r\n]*|--[^\r\n]*"#, [], .comment),
            (#"/\*[\s\S]*?\*/|<!--[\s\S]*?-->"#, [], .comment),
            (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, [], .string),
            (#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, [], .number),
            (keywordPattern, [.caseInsensitive], .keyword),
        ]
        for (pattern, options, kind) in specifications {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options)
            else {
                continue
            }
            expression.enumerateMatches(in: source, range: range) { match, _, stop in
                guard let match else { return }
                tokens.append(SyntaxToken(range: match.range, kind: kind))
                if tokens.count >= maximumTokenCount {
                    stop.pointee = true
                }
            }
            if tokens.count >= maximumTokenCount { break }
        }
        return tokens.sorted(by: tokenOrdering)
    }

    private static let keywordPattern =
        #"\b(?:actor|as|async|await|break|case|catch|class|const|continue|default|defer|do|else|enum|export|extends|extension|false|for|from|func|function|guard|if|implements|import|in|interface|is|let|match|mut|namespace|new|nil|null|private|protocol|public|return|self|static|struct|super|switch|throw|throws|trait|true|try|type|var|where|while|yield)\b"#

    private static func tokenOrdering(_ lhs: SyntaxToken, _ rhs: SyntaxToken) -> Bool {
        if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
        if lhs.range.location != rhs.range.location {
            return lhs.range.location < rhs.range.location
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}
