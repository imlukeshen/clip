import CoreModel
import Foundation
import SwiftTreeSitter

/// An editor-scoped, background-safe incremental syntax parser.
///
/// Each editor owns one instance so its parser and previous tree remain isolated.
/// Calls are serialized by the actor, while only the requested viewport plus a
/// 200-line margin is converted into style tokens.
public actor SyntaxHighlighter {
    private static let maximumTokenCount = 40_000

    private var language: LanguageID?
    private var parser: Parser?
    private var tree: MutableTree?
    private var source = ""

    /// Creates an empty highlighting session.
    public init() {}

    /// Parses the current buffer and returns bounded syntax roles for the viewport.
    ///
    /// - Parameters:
    ///   - source: The complete editor buffer.
    ///   - language: The detected or explicitly selected language.
    ///   - visibleRange: The visible UTF-16 range in the AppKit text view.
    ///   - edit: The character replacement since the previous call, when known.
    /// - Returns: Tokens for the visible range plus a 200-line margin.
    public func highlights(
        in source: String,
        language: LanguageID,
        visibleRange: NSRange,
        edit: SyntaxEdit? = nil
    ) -> SyntaxHighlightResult {
        let styledRange = SyntaxHighlightRange.around(visibleRange, in: source)
        guard language != .plainText else {
            reset(for: language, source: source)
            return SyntaxHighlightResult(
                tokens: [],
                styledRange: styledRange,
                quality: .plain
            )
        }
        if language == self.language, source == self.source, let tree {
            return SyntaxHighlightResult(
                tokens: tokens(in: tree, intersecting: styledRange),
                styledRange: styledRange,
                quality: .treeSitter
            )
        }
        guard let parser = parser(for: language) else {
            self.source = source
            return SyntaxHighlightResult(
                tokens: RegexSyntaxHighlighter.tokens(
                    in: source,
                    language: language,
                    range: styledRange
                ),
                styledRange: styledRange,
                quality: .regex
            )
        }
        guard
            let parsedTree = parse(
                source,
                with: parser,
                edit: edit
            )
        else {
            self.source = source
            return SyntaxHighlightResult(
                tokens: RegexSyntaxHighlighter.tokens(
                    in: source,
                    language: language,
                    range: styledRange
                ),
                styledRange: styledRange,
                quality: .regex
            )
        }
        self.source = source
        tree = parsedTree
        return SyntaxHighlightResult(
            tokens: tokens(in: parsedTree, intersecting: styledRange),
            styledRange: styledRange,
            quality: .treeSitter
        )
    }

    private func parser(for requestedLanguage: LanguageID) -> Parser? {
        if language == requestedLanguage { return parser }
        guard
            let treeSitterLanguage = TreeSitterLanguageRegistry.language(
                for: requestedLanguage
            )
        else {
            reset(for: requestedLanguage, source: "")
            return nil
        }
        let parser = Parser()
        parser.timeout = 0.75
        guard (try? parser.setLanguage(treeSitterLanguage)) != nil else {
            reset(for: requestedLanguage, source: "")
            return nil
        }
        language = requestedLanguage
        self.parser = parser
        tree = nil
        source = ""
        return parser
    }

    private func parse(
        _ currentSource: String,
        with parser: Parser,
        edit: SyntaxEdit?
    ) -> MutableTree? {
        guard let tree, let edit, editIsCompatible(edit, currentSource: currentSource) else {
            return parser.parse(currentSource)
        }
        let inputEdit = InputEdit(
            startByte: edit.previousRange.location * 2,
            oldEndByte: NSMaxRange(edit.previousRange) * 2,
            newEndByte: NSMaxRange(edit.currentRange) * 2,
            startPoint: point(at: edit.previousRange.location, in: source),
            oldEndPoint: point(at: NSMaxRange(edit.previousRange), in: source),
            newEndPoint: point(at: NSMaxRange(edit.currentRange), in: currentSource)
        )
        tree.edit(inputEdit)
        return parser.parse(tree: tree, string: currentSource)
    }

    private func editIsCompatible(_ edit: SyntaxEdit, currentSource: String) -> Bool {
        let previousLength = (source as NSString).length
        let currentLength = (currentSource as NSString).length
        guard edit.previousRange.location >= 0, edit.currentRange.location >= 0,
            NSMaxRange(edit.previousRange) <= previousLength,
            NSMaxRange(edit.currentRange) <= currentLength,
            edit.previousRange.location == edit.currentRange.location
        else { return false }
        return previousLength - edit.previousRange.length + edit.currentRange.length
            == currentLength
    }

    private func point(at utf16Offset: Int, in source: String) -> Point {
        let text = source as NSString
        let offset = min(max(utf16Offset, 0), text.length)
        var row = 0
        var lineStart = 0
        var cursor = 0
        while cursor < offset {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineEnd = min(NSMaxRange(line), offset)
            if lineEnd > offset || (lineEnd == offset && lineEnd == text.length) {
                lineStart = line.location
                break
            }
            row += 1
            cursor = max(lineEnd, cursor + 1)
            lineStart = cursor
        }
        return Point(row: row, column: (offset - lineStart) * 2)
    }

    private func tokens(
        in tree: MutableTree,
        intersecting styledRange: NSRange
    ) -> [SyntaxToken] {
        guard styledRange.length > 0 else { return [] }
        let lowerByte = UInt32(clamping: styledRange.location * 2)
        let upperByte = UInt32(clamping: NSMaxRange(styledRange) * 2)
        guard lowerByte < upperByte else { return [] }
        var tokens: [SyntaxToken] = []
        var seen: Set<TokenKey> = []
        tree.enumerateNodes(in: lowerByte..<upperByte) { node in
            guard tokens.count < Self.maximumTokenCount, let type = node.nodeType,
                let kind = TreeSitterTokenClassifier.kind(for: type)
            else { return }
            let range = NSIntersectionRange(node.range, styledRange)
            guard range.length > 0 else { return }
            let key = TokenKey(range: range, kind: kind)
            guard seen.insert(key).inserted else { return }
            tokens.append(SyntaxToken(range: range, kind: kind))
        }
        return tokens.sorted(by: tokenOrdering)
    }

    private func tokenOrdering(_ lhs: SyntaxToken, _ rhs: SyntaxToken) -> Bool {
        if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
        if lhs.range.location != rhs.range.location {
            return lhs.range.location < rhs.range.location
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    private func reset(for language: LanguageID, source: String) {
        self.language = language
        parser = nil
        tree = nil
        self.source = source
    }

    private struct TokenKey: Hashable {
        var location: Int
        var length: Int
        var kind: SyntaxTokenKind

        init(range: NSRange, kind: SyntaxTokenKind) {
            self.location = range.location
            self.length = range.length
            self.kind = kind
        }
    }
}
