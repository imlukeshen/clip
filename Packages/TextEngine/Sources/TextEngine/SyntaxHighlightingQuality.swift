/// Identifies the engine that produced a highlighting result.
public enum SyntaxHighlightingQuality: String, Sendable, Equatable {
    /// Incremental parsing through a bundled Tree-sitter grammar.
    case treeSitter
    /// Bounded regular-expression highlighting for an unbundled language.
    case regex
    /// Plain text with no syntax styling.
    case plain
}
