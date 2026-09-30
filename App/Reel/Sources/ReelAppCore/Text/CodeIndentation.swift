import CoreModel
import Foundation

/// Language-aware indentation for the code editor's Return, Tab, and Delete keys.
///
/// Every programming language opens a block after an open bracket, and Python
/// and YAML after a trailing colon. Python also closes a block after a
/// statement that ends it. Code indents with spaces except Go, whose own
/// formatter uses tabs; prose, LaTeX, and plain text keep the editor's plain
/// behaviour of copying the current line's indentation.
public enum CodeIndentation {
    private static let softTabLanguages: Set<LanguageID> = [
        .python, .javascript, .typescript, .swift, .rust, .c, .cpp, .java, .bash, .sql,
        .json, .yaml, .toml, .html, .css, .xml,
    ]

    private static let blockLanguages: Set<LanguageID> = softTabLanguages.union([.go])

    /// Whether Tab inserts spaces rather than a tab character.
    public static func usesSoftTabs(for language: LanguageID) -> Bool {
        softTabLanguages.contains(language)
    }

    /// Whether Return and closing brackets manage indentation for `language`.
    public static func managesBlocks(for language: LanguageID) -> Bool {
        blockLanguages.contains(language)
    }

    /// One level of indentation in `language`.
    public static func unit(for language: LanguageID, width: Int) -> String {
        usesSoftTabs(for: language) ? String(repeating: " ", count: max(width, 1)) : "\t"
    }

    /// The text Return inserts between an open and close bracket, and where
    /// the caret lands in it: `{|}` becomes an indented empty line inside the
    /// block with the closing bracket on its own line below.
    ///
    /// Returns `nil` unless the caret sits directly between a matching pair.
    public static func blockExpansion(
        lineBeforeCaret: String,
        characterAfterCaret: Character?,
        language: LanguageID,
        width: Int
    ) -> (text: String, caretOffset: Int)? {
        guard managesBlocks(for: language), let opening = lineBeforeCaret.last,
            let closing = characterAfterCaret, pairs[opening] == closing
        else { return nil }
        let outer = String(lineBeforeCaret.prefix { $0 == " " || $0 == "\t" })
        let inner = "\n" + outer + unit(for: language, width: width)
        return (inner + "\n" + outer, (inner as NSString).length)
    }

    /// How many characters to remove before a typed closing bracket so it
    /// lines up with the line that opened the block.
    ///
    /// Returns `nil` unless the line so far is only indentation.
    public static func closingBracketDedent(
        lineBeforeCaret: String,
        typed: String,
        language: LanguageID,
        width: Int
    ) -> Int? {
        guard managesBlocks(for: language), language != .python, typed.count == 1,
            let character = typed.first, pairs.values.contains(character),
            !lineBeforeCaret.isEmpty,
            lineBeforeCaret.allSatisfy({ $0 == " " || $0 == "\t" })
        else { return nil }
        if lineBeforeCaret.hasSuffix("\t") { return 1 }
        let trailingSpaces = lineBeforeCaret.reversed().prefix { $0 == " " }.count
        let removable = min(trailingSpaces, max(width, 1))
        return removable > 0 ? removable : nil
    }

    private static let pairs: [Character: Character] = ["{": "}", "(": ")", "[": "]"]

    /// The indentation for the line Return is about to start.
    ///
    /// - Parameters:
    ///   - lineBeforeCaret: The current line from its start up to the caret.
    ///   - language: The document language.
    ///   - width: The configured tab width.
    public static func newlineIndentation(
        after lineBeforeCaret: String,
        language: LanguageID,
        width: Int
    ) -> String {
        let indentation = String(lineBeforeCaret.prefix { $0 == " " || $0 == "\t" })
        guard managesBlocks(for: language) else { return indentation }
        let unit = unit(for: language, width: width)
        let code =
            (language == .python || language == .yaml || language == .bash
            ? codeBeforeHashComment(in: lineBeforeCaret) : lineBeforeCaret)
            .trimmingCharacters(in: .whitespaces)
        let opensWithColon = (language == .python || language == .yaml) && code.hasSuffix(":")
        if opensWithColon || opensBracket(code) {
            return indentation + unit
        }
        if language == .python, closesBlock(code) {
            return dedented(indentation, width: width)
        }
        return indentation
    }

    /// Spaces that advance the caret to the next tab stop.
    ///
    /// - Parameter column: The caret's zero-based column, counted in characters.
    public static func softTab(atColumn column: Int, width: Int) -> String {
        let width = max(width, 1)
        return String(repeating: " ", count: width - (max(column, 0) % width))
    }

    /// How many characters Delete removes when the caret sits in leading spaces,
    /// so a soft tab is undone in one keystroke like the tab it stands for.
    ///
    /// Returns `nil` when ordinary one-character deletion applies.
    public static func softTabDeletionLength(
        lineBeforeCaret: String,
        width: Int
    ) -> Int? {
        let width = max(width, 1)
        guard !lineBeforeCaret.isEmpty, lineBeforeCaret.allSatisfy({ $0 == " " }) else {
            return nil
        }
        let remainder = lineBeforeCaret.count % width
        return remainder == 0 ? width : remainder
    }

    private static let blockClosingStatements: Set<String> = [
        "return", "pass", "raise", "break", "continue",
    ]

    private static func closesBlock(_ code: String) -> Bool {
        let firstWord = code.prefix { $0.isLetter || $0 == "_" }
        return blockClosingStatements.contains(String(firstWord))
    }

    private static func opensBracket(_ code: String) -> Bool {
        guard let last = code.last else { return false }
        return last == "(" || last == "[" || last == "{"
    }

    /// The line without a trailing `#` comment, skipping `#` inside strings.
    private static func codeBeforeHashComment(in line: String) -> String {
        var quote: Character?
        var isEscaped = false
        for index in line.indices {
            let character = line[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func dedented(_ indentation: String, width: Int) -> String {
        if indentation.hasSuffix("\t") { return String(indentation.dropLast()) }
        let trailingSpaces = indentation.reversed().prefix { $0 == " " }.count
        let removable = min(trailingSpaces, max(width, 1))
        return String(indentation.dropLast(removable))
    }
}
