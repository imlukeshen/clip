/// Semantic syntax roles emitted by the highlighting engine.
public enum SyntaxTokenKind: String, Sendable, Equatable, Hashable {
    /// A language keyword or declaration modifier.
    case keyword
    /// A quoted string, character, or template literal.
    case string
    /// A source comment.
    case comment
    /// An integer, floating-point value, or other numeric literal.
    case number
    /// A declared, referenced, or built-in type.
    case type
    /// A function or method name.
    case function
    /// A property, field, key, or attribute name.
    case property
    /// A markup tag or LaTeX command.
    case tag
    /// A Markdown heading.
    case heading
    /// Emphasized markup content.
    case emphasis
    /// A link or URL.
    case link
    /// An escape sequence within another token.
    case escape
    /// A language operator.
    case `operator`
}
