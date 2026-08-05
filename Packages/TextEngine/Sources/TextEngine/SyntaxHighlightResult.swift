import Foundation

/// The bounded syntax styling for one editor viewport and its line margin.
public struct SyntaxHighlightResult: Sendable, Equatable {
    /// Tokens intersecting the styled range.
    public var tokens: [SyntaxToken]
    /// The UTF-16 range that should have existing syntax attributes reset first.
    public var styledRange: NSRange
    /// The engine that produced the result.
    public var quality: SyntaxHighlightingQuality

    /// Creates a syntax highlighting result.
    public init(
        tokens: [SyntaxToken],
        styledRange: NSRange,
        quality: SyntaxHighlightingQuality
    ) {
        self.tokens = tokens
        self.styledRange = styledRange
        self.quality = quality
    }
}
