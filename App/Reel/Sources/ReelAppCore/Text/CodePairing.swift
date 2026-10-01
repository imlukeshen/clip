import CoreModel
import Foundation

/// What typing a bracket or quote does: step over the closer already there,
/// insert a pair (wrapping any selection), or insert the character alone.
public enum CodePairing: Equatable, Sendable {
    /// Move the caret past the identical character after it.
    case stepOver
    /// Insert the character and this closer around the selection.
    case pair(closing: String)
    /// Insert only what was typed.
    case insert

    private static let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
    private static let proseLanguages: Set<LanguageID> = [.markdown, .plainText, .latex]

    /// The action for typing `typed` between `before` and `after`.
    ///
    /// A quote is both an opener and a closer, so stepping over is checked
    /// first. It only opens a pair where it plausibly starts a string: not
    /// straight after a letter or digit (`don't`, `it's`), not before one, and
    /// in prose only when wrapping a selection, since prose quotes are mostly
    /// apostrophes.
    public static func action(
        typing typed: String,
        before: Character?,
        after: Character?,
        hasSelection: Bool,
        language: LanguageID
    ) -> CodePairing {
        if !hasSelection, let after, String(after) == typed, pairs.values.contains(typed) {
            return .stepOver
        }
        guard let closing = pairs[typed] else { return .insert }
        if typed == "\"" || typed == "'" {
            if hasSelection { return .pair(closing: closing) }
            if proseLanguages.contains(language) { return .insert }
            if let before, before.isLetter || before.isNumber { return .insert }
            if let after, after.isLetter || after.isNumber { return .insert }
        }
        return .pair(closing: closing)
    }
}
