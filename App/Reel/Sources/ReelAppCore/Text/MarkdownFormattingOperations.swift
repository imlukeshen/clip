import CoreModel
import Foundation
import TextEngine

/// Selection-aware Markdown commands used by Clip's inline writing canvas.
public enum MarkdownFormattingAction: Sendable, Equatable {
    case body
    case heading1
    case heading2
    case heading3
    case heading4
    case heading5
    case heading6
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case bulletedList
    case numberedList
    case checklist
    case quote
    case codeBlock
    case image
    case table
    case footnote
    case inlineMath
    case mathBlock
    case divider
}

/// The block style at the insertion point. Keeping this derived from the
/// portable Markdown source lets the toolbar behave like a rich-text editor
/// without introducing a second, lossy document model.
public enum MarkdownBlockStyle: Sendable, Equatable {
    case body
    case heading(Int)
    case bulletedList
    case numberedList
    case checklist
    case quote

    public var displayName: String {
        switch self {
        case .body: "Text"
        case .heading(let level): "Heading \(level)"
        case .bulletedList: "Bulleted list"
        case .numberedList: "Numbered list"
        case .checklist: "Checklist"
        case .quote: "Quote"
        }
    }
}

/// Pure Markdown transformations so toolbar and keyboard commands remain undoable and testable.
public enum MarkdownFormattingOperations {
    /// Makes an unfinished ATX heading behave like a block-editor shortcut.
    /// Typing the first content character after one to six leading `#` markers
    /// inserts Markdown's required separator as part of the same undoable edit.
    public static func preparingTypedInsertion(
        _ insertion: String,
        in text: String,
        selectedRange requestedRange: NSRange
    ) -> TextEditResult? {
        guard insertion.utf16.count == 1,
            insertion != "#",
            insertion.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        let source = text as NSString
        let selection = clamped(requestedRange, in: source)
        guard selection.length == 0 else { return nil }
        let lineRange = source.lineRange(
            for: NSRange(location: selection.location, length: 0)
        )
        let beforeCaret = source.substring(
            with: NSRange(
                location: lineRange.location,
                length: selection.location - lineRange.location
            )
        )
        guard
            let expression = try? NSRegularExpression(pattern: "^[ \\t]*#{1,6}$"),
            expression.firstMatch(
                in: beforeCaret,
                range: NSRange(location: 0, length: (beforeCaret as NSString).length)
            ) != nil
        else { return nil }
        let replacement = " " + insertion
        return replacing(
            selection,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selection.location + (replacement as NSString).length,
                length: 0
            )
        )
    }

    /// Returns the semantic block style at the start of the current selection.
    public static func blockStyle(
        in text: String,
        selectedRange requestedRange: NSRange
    ) -> MarkdownBlockStyle {
        let source = text as NSString
        let range = clamped(requestedRange, in: source)
        let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
        let line = parsedLines(in: source.substring(with: lineRange)).first?.body ?? ""
        return parsedBlockLine(line).style
    }

    /// Reports active inline formatting so toolbar state follows the caret or
    /// selection instead of resetting visually after every edit.
    public static func isInlineStyleActive(
        _ action: MarkdownFormattingAction,
        in text: String,
        selectedRange requestedRange: NSRange
    ) -> Bool {
        let pattern: String
        switch action {
        case .bold: pattern = "\\*\\*[^\\n*]+\\*\\*|__[^\\n_]+__"
        case .italic: pattern = "(?<!\\*)\\*[^*\\n]+\\*(?!\\*)|(?<!_)_[^_\\n]+_(?!_)"
        case .strikethrough: pattern = "~~[^\\n~]+~~"
        case .inlineCode: pattern = "(?<!`)`[^`\\n]+`(?!`)"
        case .link: pattern = "\\[[^\\]\\n]+\\]\\([^)\\n]+\\)"
        case .inlineMath: pattern = "(?<!\\$)\\$[^\\n$]+\\$(?!\\$)"
        default: return false
        }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let source = text as NSString
        let selection = clamped(requestedRange, in: source)
        let lineRange = source.lineRange(
            for: NSRange(location: selection.location, length: 0)
        )
        guard selection.length == 0 || NSMaxRange(selection) <= NSMaxRange(lineRange) else {
            return false
        }
        return expression.matches(
            in: text,
            range: lineRange
        ).contains { match in
            if selection.length == 0 {
                return selection.location > match.range.location
                    && selection.location < NSMaxRange(match.range)
            }
            return NSIntersectionRange(selection, match.range).length == selection.length
        }
    }

    public static func apply(
        _ action: MarkdownFormattingAction,
        to text: String,
        selectedRange requestedRange: NSRange
    ) -> TextEditResult {
        let source = text as NSString
        let range = clamped(requestedRange, in: source)
        switch action {
        case .body:
            return changeBlock(in: source, selectedRange: range, to: .body)
        case .heading1:
            return changeBlock(in: source, selectedRange: range, to: .heading(1))
        case .heading2:
            return changeBlock(in: source, selectedRange: range, to: .heading(2))
        case .heading3:
            return changeBlock(in: source, selectedRange: range, to: .heading(3))
        case .heading4:
            return changeBlock(in: source, selectedRange: range, to: .heading(4))
        case .heading5:
            return changeBlock(in: source, selectedRange: range, to: .heading(5))
        case .heading6:
            return changeBlock(in: source, selectedRange: range, to: .heading(6))
        case .bold:
            return wrap(
                in: source, selectedRange: range, opening: "**", closing: "**",
                placeholder: "bold text")
        case .italic:
            return wrap(
                in: source, selectedRange: range, opening: "_", closing: "_",
                placeholder: "italic text")
        case .strikethrough:
            return wrap(
                in: source, selectedRange: range, opening: "~~", closing: "~~",
                placeholder: "strikethrough")
        case .inlineCode:
            return wrap(
                in: source, selectedRange: range, opening: "`", closing: "`", placeholder: "code")
        case .link:
            return insertLink(in: source, selectedRange: range)
        case .bulletedList:
            return changeBlock(in: source, selectedRange: range, to: .bulletedList, toggles: true)
        case .numberedList:
            return changeBlock(in: source, selectedRange: range, to: .numberedList, toggles: true)
        case .checklist:
            return changeBlock(in: source, selectedRange: range, to: .checklist, toggles: true)
        case .quote:
            return changeBlock(in: source, selectedRange: range, to: .quote, toggles: true)
        case .codeBlock:
            return insertCodeBlock(in: source, selectedRange: range)
        case .image:
            return insertImage(in: source, selectedRange: range)
        case .table:
            return insertTable(in: source, selectedRange: range)
        case .footnote:
            return insertFootnote(in: source, selectedRange: range)
        case .inlineMath:
            return wrap(
                in: source, selectedRange: range, opening: "$", closing: "$",
                placeholder: "x^2")
        case .mathBlock:
            return insertMathBlock(in: source, selectedRange: range)
        case .divider:
            return insertDivider(in: source, selectedRange: range)
        }
    }

    /// Inserts pasted code as a language-labelled Markdown fence.
    public static func insertingCodeBlock(
        contents: String,
        language: LanguageID,
        into text: String,
        selectedRange requestedRange: NSRange
    ) -> TextEditResult {
        let source = text as NSString
        let range = clamped(requestedRange, in: source)
        return insertCodeBlock(
            in: source,
            selectedRange: range,
            contents: contents,
            languageLabel: MarkdownEditingIntelligence.fenceLabel(for: language)
        )
    }

    private static func wrap(
        in source: NSString,
        selectedRange: NSRange,
        opening: String,
        closing: String,
        placeholder: String
    ) -> TextEditResult {
        let openingLength = (opening as NSString).length
        let closingLength = (closing as NSString).length
        let selected = source.substring(with: selectedRange)

        if selectedRange.length >= openingLength + closingLength,
            selected.hasPrefix(opening), selected.hasSuffix(closing)
        {
            let inner = String(selected.dropFirst(opening.count).dropLast(closing.count))
            return replacing(
                selectedRange,
                in: source,
                with: inner,
                selection: NSRange(
                    location: selectedRange.location, length: (inner as NSString).length)
            )
        }

        let before = selectedRange.location - openingLength
        let after = NSMaxRange(selectedRange)
        if before >= 0, after + closingLength <= source.length,
            source.substring(with: NSRange(location: before, length: openingLength)) == opening,
            source.substring(with: NSRange(location: after, length: closingLength)) == closing
        {
            let combined = NSRange(
                location: before,
                length: openingLength + selectedRange.length + closingLength
            )
            return replacing(
                combined,
                in: source,
                with: selected,
                selection: NSRange(location: before, length: selectedRange.length)
            )
        }

        let content = selectedRange.length == 0 ? placeholder : selected
        let replacement = opening + content + closing
        return replacing(
            selectedRange,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selectedRange.location + openingLength,
                length: (content as NSString).length
            )
        )
    }

    private static func insertLink(in source: NSString, selectedRange: NSRange) -> TextEditResult {
        let label = selectedRange.length == 0 ? "link text" : source.substring(with: selectedRange)
        let destination = "https://"
        let replacement = "[\(label)](\(destination))"
        let destinationOffset = ("[\(label)](" as NSString).length
        return replacing(
            selectedRange,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selectedRange.location + destinationOffset,
                length: (destination as NSString).length
            )
        )
    }

    private static func changeBlock(
        in source: NSString,
        selectedRange: NSRange,
        to requestedStyle: MarkdownBlockStyle,
        toggles: Bool = false
    ) -> TextEditResult {
        let affected = affectedLineRange(in: source, selection: selectedRange)
        let lines = parsedLines(in: source.substring(with: affected))
        let parsed = lines.map { parsedBlockLine($0.body) }
        let style: MarkdownBlockStyle =
            toggles && parsed.allSatisfy({ $0.style == requestedStyle })
            ? .body : requestedStyle
        var replacement = ""
        var mappings: [BlockLineMapping] = []
        var oldOffset = 0
        var newOffset = 0
        for (index, pair) in zip(lines, parsed).enumerated() {
            let (line, block) = pair
            let prefix = blockPrefix(for: style, lineIndex: index)
            let updatedBody = block.indentation + prefix + block.content
            let oldBodyLength = (line.body as NSString).length
            let oldTerminatorLength = (line.terminator as NSString).length
            let newBodyLength = (updatedBody as NSString).length
            mappings.append(
                BlockLineMapping(
                    oldStart: oldOffset,
                    oldBodyLength: oldBodyLength,
                    oldTerminatorLength: oldTerminatorLength,
                    oldContentStart: ((block.indentation + block.prefix) as NSString).length,
                    contentLength: (block.content as NSString).length,
                    newStart: newOffset,
                    newBodyLength: newBodyLength,
                    newTerminatorLength: oldTerminatorLength,
                    newContentStart: ((block.indentation + prefix) as NSString).length
                )
            )
            replacement += updatedBody + line.terminator
            oldOffset += oldBodyLength + oldTerminatorLength
            newOffset += newBodyLength + oldTerminatorLength
        }
        let localStart = selectedRange.location - affected.location
        let localEnd = NSMaxRange(selectedRange) - affected.location
        let mappedStart = mapBlockPosition(localStart, through: mappings)
        let mappedEnd = mapBlockPosition(localEnd, through: mappings)
        return replacing(
            affected,
            in: source,
            with: replacement,
            selection: NSRange(
                location: affected.location + mappedStart,
                length: max(mappedEnd - mappedStart, 0)
            )
        )
    }

    private static func insertCodeBlock(
        in source: NSString,
        selectedRange: NSRange
    ) -> TextEditResult {
        insertCodeBlock(
            in: source,
            selectedRange: selectedRange,
            contents: selectedRange.length == 0 ? "code" : source.substring(with: selectedRange),
            languageLabel: ""
        )
    }

    private struct ParsedBlockLine {
        var indentation: String
        var prefix: String
        var content: String
        var style: MarkdownBlockStyle
    }

    private struct BlockLineMapping {
        var oldStart: Int
        var oldBodyLength: Int
        var oldTerminatorLength: Int
        var oldContentStart: Int
        var contentLength: Int
        var newStart: Int
        var newBodyLength: Int
        var newTerminatorLength: Int
        var newContentStart: Int
    }

    private static func parsedBlockLine(_ line: String) -> ParsedBlockLine {
        let parts = indentationAndBody(line)
        let body = parts.body as NSString
        let fullRange = NSRange(location: 0, length: body.length)
        let patterns: [(String, (NSTextCheckingResult) -> MarkdownBlockStyle)] = [
            (
                "^(#{1,6})(?:[ \\t]+|$)",
                { match in .heading(min(max(match.range(at: 1).length, 1), 6)) }
            ),
            ("^[-+*][ \\t]+\\[[ xX]\\][ \\t]+", { _ in .checklist }),
            ("^[0-9]+\\.[ \\t]+", { _ in .numberedList }),
            ("^[-+*][ \\t]+", { _ in .bulletedList }),
            ("^>[ \\t]+", { _ in .quote }),
        ]
        for (pattern, style) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                let match = expression.firstMatch(in: parts.body, range: fullRange)
            else { continue }
            let prefix = body.substring(with: match.range)
            return ParsedBlockLine(
                indentation: parts.indentation,
                prefix: prefix,
                content: body.substring(from: NSMaxRange(match.range)),
                style: style(match)
            )
        }
        return ParsedBlockLine(
            indentation: parts.indentation,
            prefix: "",
            content: parts.body,
            style: .body
        )
    }

    private static func blockPrefix(for style: MarkdownBlockStyle, lineIndex: Int) -> String {
        switch style {
        case .body: ""
        case .heading(let level): String(repeating: "#", count: min(max(level, 1), 6)) + " "
        case .bulletedList: "- "
        case .numberedList: "\(lineIndex + 1). "
        case .checklist: "- [ ] "
        case .quote: "> "
        }
    }

    private static func mapBlockPosition(
        _ requestedPosition: Int,
        through mappings: [BlockLineMapping]
    ) -> Int {
        let position = max(requestedPosition, 0)
        for (index, mapping) in mappings.enumerated() {
            let oldBodyEnd = mapping.oldStart + mapping.oldBodyLength
            let oldLineEnd = oldBodyEnd + mapping.oldTerminatorLength
            if position < mapping.oldStart { return mapping.newStart }
            if position <= oldBodyEnd {
                let local = position - mapping.oldStart
                guard local > mapping.oldContentStart else {
                    return mapping.newStart + mapping.newContentStart
                }
                return mapping.newStart + mapping.newContentStart
                    + min(local - mapping.oldContentStart, mapping.contentLength)
            }
            if position < oldLineEnd || index == mappings.count - 1 {
                let terminatorOffset = min(
                    max(position - oldBodyEnd, 0),
                    mapping.newTerminatorLength
                )
                return mapping.newStart + mapping.newBodyLength + terminatorOffset
            }
        }
        guard let last = mappings.last else { return position }
        return last.newStart + last.newBodyLength + last.newTerminatorLength
    }

    private static func insertCodeBlock(
        in source: NSString,
        selectedRange: NSRange,
        contents: String,
        languageLabel: String
    ) -> TextEditResult {
        let selected = contents.trimmingCharacters(in: .newlines)
        if selected.hasPrefix("```\n"), selected.hasSuffix("\n```") {
            let inner = String(selected.dropFirst(4).dropLast(4))
            return replacing(
                selectedRange,
                in: source,
                with: inner,
                selection: NSRange(
                    location: selectedRange.location, length: (inner as NSString).length)
            )
        }
        let leadingBreak =
            selectedRange.location > 0 && source.character(at: selectedRange.location - 1) != 0x0A
            ? "\n" : ""
        let trailingBreak =
            NSMaxRange(selectedRange) < source.length
                && source.character(at: NSMaxRange(selectedRange)) != 0x0A ? "\n" : ""
        let opening = leadingBreak + "```" + languageLabel + "\n"
        let replacement = opening + selected + "\n```" + trailingBreak
        return replacing(
            selectedRange,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selectedRange.location + (opening as NSString).length,
                length: (selected as NSString).length
            )
        )
    }

    private static func insertImage(in source: NSString, selectedRange: NSRange) -> TextEditResult {
        let label =
            selectedRange.length == 0 ? "Image description" : source.substring(with: selectedRange)
        let destination = "image.png"
        let replacement = "![\(label)](\(destination))"
        let destinationOffset = ("![\(label)](" as NSString).length
        return replacing(
            selectedRange,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selectedRange.location + destinationOffset,
                length: (destination as NSString).length
            )
        )
    }

    private static func insertTable(in source: NSString, selectedRange: NSRange) -> TextEditResult {
        let leadingBreak = lineBreakBeforeInsertion(in: source, selectedRange: selectedRange)
        let trailingBreak = lineBreakAfterInsertion(in: source, selectedRange: selectedRange)
        let table = "| Column 1 | Column 2 |\n| --- | --- |\n| Value | Value |"
        let replacement = leadingBreak + table + trailingBreak
        let editable = "Column 1"
        return replacing(
            selectedRange,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selectedRange.location + (leadingBreak + "| " as NSString).length,
                length: (editable as NSString).length
            )
        )
    }

    private static func insertFootnote(
        in source: NSString,
        selectedRange: NSRange
    ) -> TextEditResult {
        let index = nextFootnoteIndex(in: source as String)
        let label = selectedRange.length == 0 ? "Reference" : source.substring(with: selectedRange)
        let definition = "Footnote text"
        let marker = "[^\(index)]"
        let reference = "\(label)\(marker)"
        let withReference = source.replacingCharacters(in: selectedRange, with: reference)
        let needsBreak = withReference.hasSuffix("\n") ? "\n" : "\n\n"
        let definitionPrefix = needsBreak + "\(marker): "
        let updated = withReference + definitionPrefix + definition
        return TextEditResult(
            text: updated,
            selectedRange: NSRange(
                location: ((withReference + definitionPrefix) as NSString).length,
                length: (definition as NSString).length
            )
        )
    }

    private static func insertMathBlock(
        in source: NSString,
        selectedRange: NSRange
    ) -> TextEditResult {
        let content = selectedRange.length == 0 ? "E = mc^2" : source.substring(with: selectedRange)
        let leadingBreak = lineBreakBeforeInsertion(in: source, selectedRange: selectedRange)
        let trailingBreak = lineBreakAfterInsertion(in: source, selectedRange: selectedRange)
        let opening = leadingBreak + "$$\n"
        let replacement = opening + content + "\n$$" + trailingBreak
        return replacing(
            selectedRange,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selectedRange.location + (opening as NSString).length,
                length: (content as NSString).length
            )
        )
    }

    private static func insertDivider(in source: NSString, selectedRange: NSRange) -> TextEditResult
    {
        let leadingBreak = lineBreakBeforeInsertion(in: source, selectedRange: selectedRange)
        let trailingBreak = lineBreakAfterInsertion(in: source, selectedRange: selectedRange)
        let replacement = leadingBreak + "---\n" + trailingBreak
        return replacing(
            selectedRange,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selectedRange.location + (replacement as NSString).length, length: 0)
        )
    }

    private static func lineBreakBeforeInsertion(
        in source: NSString,
        selectedRange: NSRange
    ) -> String {
        selectedRange.location > 0 && source.character(at: selectedRange.location - 1) != 0x0A
            ? "\n" : ""
    }

    private static func lineBreakAfterInsertion(
        in source: NSString,
        selectedRange: NSRange
    ) -> String {
        NSMaxRange(selectedRange) < source.length
            && source.character(at: NSMaxRange(selectedRange)) != 0x0A ? "\n" : ""
    }

    private static func nextFootnoteIndex(in source: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: "\\[\\^([0-9]+)\\]") else {
            return 1
        }
        let text = source as NSString
        let indexes = expression.matches(
            in: source,
            range: NSRange(location: 0, length: text.length)
        ).compactMap { match -> Int? in
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return nil }
            return Int(text.substring(with: range))
        }
        return (indexes.max() ?? 0) + 1
    }

    private static func indentationAndBody(_ line: String) -> (indentation: String, body: String) {
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        return (indentation, String(line.dropFirst(indentation.count)))
    }

    private static func affectedLineRange(in source: NSString, selection: NSRange) -> NSRange {
        var length = selection.length
        if length > 0, NSMaxRange(selection) < source.length {
            let finalCharacter = source.character(at: NSMaxRange(selection) - 1)
            if finalCharacter == 0x0A || finalCharacter == 0x0D { length -= 1 }
        }
        return source.lineRange(for: NSRange(location: selection.location, length: length))
    }

    private static func parsedLines(in text: String) -> [(body: String, terminator: String)] {
        let source = text as NSString
        guard source.length > 0 else { return [("", "")] }
        var result: [(String, String)] = []
        var cursor = 0
        while cursor < source.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getLineStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            result.append(
                (
                    source.substring(with: NSRange(location: start, length: contentsEnd - start)),
                    source.substring(
                        with: NSRange(location: contentsEnd, length: end - contentsEnd))
                )
            )
            guard end > cursor else { break }
            cursor = end
        }
        return result
    }

    private static func replacing(
        _ range: NSRange,
        in source: NSString,
        with replacement: String,
        selection: NSRange
    ) -> TextEditResult {
        TextEditResult(
            text: source.replacingCharacters(in: range, with: replacement),
            selectedRange: selection
        )
    }

    private static func clamped(_ range: NSRange, in source: NSString) -> NSRange {
        let location = min(max(range.location, 0), source.length)
        let length = min(max(range.length, 0), source.length - location)
        return NSRange(location: location, length: length)
    }
}
