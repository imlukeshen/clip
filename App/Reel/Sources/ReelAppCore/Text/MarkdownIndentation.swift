import Foundation
import TextEngine

/// What Tab, Shift-Tab, and Return on an empty item do in a Markdown document.
///
/// Markdown gives leading spaces meaning, so Tab cannot simply push a line
/// right the way it does in code. A list item nests under the item above it by
/// lining up with that item's text — two columns under `- `, three under `1. `
/// — which is exactly one level for the live styling and for any renderer.
/// Inside a fenced code block Tab is an ordinary soft tab at the caret, and on
/// a plain line it inserts spaces at the caret rather than turning the whole
/// paragraph into an indented code block.
///
/// Every operation keeps a caret where it was relative to the text; only a
/// selection spanning several lines comes back selecting those lines.
public enum MarkdownIndentation {
    /// The result of pressing Tab.
    public static func tab(
        in text: String,
        selectedRange: NSRange,
        width: Int
    ) -> TextEditResult {
        let source = text as NSString
        let selection = clamped(selectedRange, in: source)
        if spansLines(selection, in: source) {
            let lines = lineRanges(covering: selection, in: source)
            let first = lines.lazy.compactMap { listItem(at: $0, in: source) }.first
            let delta =
                first.map { item in
                    nestingTarget(for: item, in: source).map { $0 - item.indentColumns } ?? 0
                } ?? max(width, 1)
            guard delta > 0 else { return unchanged(text, selection) }
            return shiftLines(lines, by: delta, in: source)
        }
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        if !MarkdownEditingIntelligence.isInsideFencedCode(location: selection.location, in: text),
            let item = listItem(at: line, in: source)
        {
            guard let target = nestingTarget(for: item, in: source) else {
                return unchanged(text, selection)
            }
            return reindent(item.line, from: item.indentLength, to: target, in: source, selection)
        }
        let column = columns(
            in: source.substring(
                with: NSRange(location: line.location, length: selection.location - line.location)
            )
        )
        let step = max(width, 1)
        let spaces = String(repeating: " ", count: step - column % step)
        return TextEditResult(
            text: source.replacingCharacters(in: selection, with: spaces),
            selectedRange: NSRange(location: selection.location + spaces.utf16.count, length: 0)
        )
    }

    /// The result of pressing Shift-Tab.
    public static func backtab(
        in text: String,
        selectedRange: NSRange,
        width: Int
    ) -> TextEditResult {
        let source = text as NSString
        let selection = clamped(selectedRange, in: source)
        if spansLines(selection, in: source) {
            let lines = lineRanges(covering: selection, in: source)
            let first = lines.lazy.compactMap { listItem(at: $0, in: source) }.first
            let delta =
                first.map { $0.indentColumns - parentColumns(for: $0, in: source) }
                ?? max(width, 1)
            guard delta > 0 else { return unchanged(text, selection) }
            return shiftLines(lines, by: -delta, in: source)
        }
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let indentLength = leadingWhitespaceLength(of: line, in: source)
        guard indentLength > 0 else { return unchanged(text, selection) }
        if !MarkdownEditingIntelligence.isInsideFencedCode(location: selection.location, in: text),
            let item = listItem(at: line, in: source)
        {
            return reindent(
                line,
                from: indentLength,
                to: parentColumns(for: item, in: source),
                in: source,
                selection
            )
        }
        let indentation = source.substring(
            with: NSRange(location: line.location, length: indentLength)
        )
        let target = max(columns(in: indentation) - max(width, 1), 0)
        return reindent(line, from: indentLength, to: target, in: source, selection)
    }

    /// What Return does on a nested list item that has no text yet: step it
    /// out one level, the way outliners do. Returns `nil` for anything else,
    /// including an empty item that is already at the left margin.
    public static func outdentingEmptyNestedItem(
        in text: String,
        caret: Int
    ) -> TextEditResult? {
        let source = text as NSString
        let location = min(max(caret, 0), source.length)
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        guard let item = listItem(at: line, in: source), item.indentColumns > 0,
            item.content.trimmingCharacters(in: .whitespaces).isEmpty,
            !MarkdownEditingIntelligence.isInsideFencedCode(location: location, in: text)
        else { return nil }
        return backtab(in: text, selectedRange: NSRange(location: location, length: 0), width: 4)
    }

    // MARK: - Lines

    private struct ListItem {
        /// The line without its terminator.
        var line: NSRange
        /// UTF-16 length of the leading whitespace.
        var indentLength: Int
        /// Display columns of the leading whitespace, tabs counting four.
        var indentColumns: Int
        /// Columns from the margin to where the item's text starts.
        var contentColumns: Int
        var content: String
    }

    private static let listPattern = try? NSRegularExpression(
        pattern: #"^([ \t]*)([-+*]|[0-9]{1,9}[.)])([ \t]+|$)(.*)$"#
    )

    private static func listItem(at lineRange: NSRange, in source: NSString) -> ListItem? {
        let line = contentRange(of: lineRange, in: source)
        let value = source.substring(with: line)
        guard let listPattern,
            let match = listPattern.firstMatch(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length)
            )
        else { return nil }
        let string = value as NSString
        let indentation = string.substring(with: match.range(at: 1))
        let marker = string.substring(with: match.range(at: 2))
        let gap = string.substring(with: match.range(at: 3))
        let indentColumns = columns(in: indentation)
        return ListItem(
            line: line,
            indentLength: match.range(at: 1).length,
            indentColumns: indentColumns,
            contentColumns: indentColumns + marker.count + max(columns(in: gap), 1),
            content: string.substring(with: match.range(at: 4))
        )
    }

    /// Where `item` lines up once nested under the sibling above it, or `nil`
    /// when there is no sibling to nest under.
    private static func nestingTarget(for item: ListItem, in source: NSString) -> Int? {
        var location = item.line.location
        while location > 0 {
            let previous = source.lineRange(for: NSRange(location: location - 1, length: 0))
            location = previous.location
            if isBlank(previous, in: source) { continue }
            guard let candidate = listItem(at: previous, in: source) else {
                // A wrapped continuation of an item above stays part of it.
                if leadingColumns(of: previous, in: source) > item.indentColumns { continue }
                return nil
            }
            if candidate.indentColumns == item.indentColumns { return candidate.contentColumns }
            if candidate.indentColumns < item.indentColumns { return nil }
        }
        return nil
    }

    /// The indentation of the item `item` is nested under, or zero at the top.
    private static func parentColumns(for item: ListItem, in source: NSString) -> Int {
        var location = item.line.location
        while location > 0 {
            let previous = source.lineRange(for: NSRange(location: location - 1, length: 0))
            location = previous.location
            if isBlank(previous, in: source) { continue }
            if let candidate = listItem(at: previous, in: source),
                candidate.indentColumns < item.indentColumns
            {
                return candidate.indentColumns
            }
            if listItem(at: previous, in: source) == nil,
                leadingColumns(of: previous, in: source) == 0
            {
                return 0
            }
        }
        return 0
    }

    private static func reindent(
        _ lineRange: NSRange,
        from indentLength: Int,
        to targetColumns: Int,
        in source: NSString,
        _ selection: NSRange
    ) -> TextEditResult {
        let indentation = String(repeating: " ", count: max(targetColumns, 0))
        let delta = indentation.utf16.count - indentLength
        let updated = source.replacingCharacters(
            in: NSRange(location: lineRange.location, length: indentLength),
            with: indentation
        )
        let indentEnd = lineRange.location + indentLength
        let start =
            selection.location >= indentEnd
            ? selection.location + delta
            : min(selection.location, lineRange.location + indentation.utf16.count)
        let end = max(NSMaxRange(selection) + delta, start)
        return TextEditResult(
            text: updated,
            selectedRange: NSRange(location: start, length: end - start)
        )
    }

    /// Adds `delta` columns to every non-blank line, or removes up to `-delta`
    /// columns of leading whitespace, and selects the lines.
    private static func shiftLines(
        _ lines: [NSRange],
        by delta: Int,
        in source: NSString
    ) -> TextEditResult {
        guard let first = lines.first, let last = lines.last else {
            return TextEditResult(text: source as String, selectedRange: NSRange())
        }
        var replacement = ""
        for line in lines {
            let content = contentRange(of: line, in: source)
            let body = source.substring(with: content)
            let terminator = source.substring(
                with: NSRange(
                    location: NSMaxRange(content), length: NSMaxRange(line) - NSMaxRange(content))
            )
            if isBlank(line, in: source) {
                replacement += body + terminator
                continue
            }
            let indentLength = leadingWhitespaceLength(of: line, in: source)
            let indentation = (body as NSString).substring(to: indentLength)
            let target = max(columns(in: indentation) + delta, 0)
            replacement +=
                String(repeating: " ", count: target)
                + (body as NSString).substring(from: indentLength) + terminator
        }
        let covered = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let updated = source.replacingCharacters(in: covered, with: replacement)
        // Leave the final terminator out so a following Tab keeps the same lines.
        var length = replacement.utf16.count
        if replacement.hasSuffix("\r\n") {
            length -= 2
        } else if replacement.hasSuffix("\n") || replacement.hasSuffix("\r") {
            length -= 1
        }
        return TextEditResult(
            text: updated,
            selectedRange: NSRange(location: first.location, length: length)
        )
    }

    private static func lineRanges(covering selection: NSRange, in source: NSString) -> [NSRange] {
        var end = NSMaxRange(selection)
        // A selection ending just after a newline does not include the next line.
        if selection.length > 0, end > selection.location,
            [10, 13].contains(source.character(at: end - 1))
        {
            end -= 1
        }
        var ranges: [NSRange] = []
        var location = selection.location
        repeat {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            ranges.append(line)
            location = NSMaxRange(line)
        } while location < end && location < source.length
        return ranges
    }

    private static func spansLines(_ selection: NSRange, in source: NSString) -> Bool {
        guard selection.length > 0 else { return false }
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        return NSMaxRange(selection) > NSMaxRange(contentRange(of: line, in: source))
    }

    private static func contentRange(of line: NSRange, in source: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location, [10, 13].contains(source.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    private static func isBlank(_ line: NSRange, in source: NSString) -> Bool {
        source.substring(with: contentRange(of: line, in: source))
            .allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func leadingWhitespaceLength(of line: NSRange, in source: NSString) -> Int {
        let content = contentRange(of: line, in: source)
        var length = 0
        while length < content.length {
            let character = source.character(at: content.location + length)
            guard character == 32 || character == 9 else { break }
            length += 1
        }
        return length
    }

    private static func leadingColumns(of line: NSRange, in source: NSString) -> Int {
        columns(
            in: source.substring(
                with: NSRange(
                    location: line.location, length: leadingWhitespaceLength(of: line, in: source))
            )
        )
    }

    private static func columns(in value: String) -> Int {
        value.reduce(0) { total, character in
            character == "\t" ? total + 4 - total % 4 : total + 1
        }
    }

    private static func clamped(_ range: NSRange, in source: NSString) -> NSRange {
        let location = min(max(range.location, 0), source.length)
        return NSRange(
            location: location, length: min(max(range.length, 0), source.length - location))
    }

    private static func unchanged(_ text: String, _ selection: NSRange) -> TextEditResult {
        TextEditResult(text: text, selectedRange: selection)
    }
}
