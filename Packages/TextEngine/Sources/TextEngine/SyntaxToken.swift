import Foundation

/// A semantic syntax role covering a UTF-16 range in an editor buffer.
public struct SyntaxToken: Sendable, Equatable {
    /// The UTF-16 range used by AppKit text storage.
    public var range: NSRange
    /// The semantic role to style.
    public var kind: SyntaxTokenKind

    /// Creates a syntax token.
    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}
