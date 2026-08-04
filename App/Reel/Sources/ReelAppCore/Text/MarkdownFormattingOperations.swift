import Foundation

/// Selection-aware Markdown commands used by Clip's inline writing canvas.
public enum MarkdownFormattingAction: Sendable, Equatable {
    case body
    case heading1
    case heading2
    case heading3
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
    case divider
}

/// Pure Markdown transformations so toolbar and keyboard commands remain undoable and testable.
public enum MarkdownFormattingOperations {
    public static func apply(
        _ action: MarkdownFormattingAction,
        to text: String,
        selectedRange requestedRange: NSRange
    ) -> TextEditResult {
        let source = text as NSString
        let range = clamped(requestedRange, in: source)
        switch action {
        case .body:
            return changeHeading(in: source, selectedRange: range, level: nil)
        case .heading1:
            return changeHeading(in: source, selectedRange: range, level: 1)
        case .heading2:
            return changeHeading(in: source, selectedRange: range, level: 2)
        case .heading3:
            return changeHeading(in: source, selectedRange: range, level: 3)
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
            return changeList(in: source, selectedRange: range, style: .bulleted)
        case .numberedList:
            return changeList(in: source, selectedRange: range, style: .numbered)
        case .checklist:
            return changeList(in: source, selectedRange: range, style: .checklist)
        case .quote:
            return toggleLinePrefix(in: source, selectedRange: range, prefix: "> ")
        case .codeBlock:
            return insertCodeBlock(in: source, selectedRange: range)
        case .divider:
            return insertDivider(in: source, selectedRange: range)
        }
    }

    private enum ListStyle {
        case bulleted
        case numbered
        case checklist
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

    private static func changeHeading(
        in source: NSString,
        selectedRange: NSRange,
        level: Int?
    ) -> TextEditResult {
        transformSelectedLines(in: source, selectedRange: selectedRange) { line, _ in
            let parts = indentationAndBody(line)
            let body = strippingHeadingPrefix(from: parts.body)
            guard let level else { return parts.indentation + body }
            return parts.indentation + String(repeating: "#", count: level) + " " + body
        }
    }

    private static func changeList(
        in source: NSString,
        selectedRange: NSRange,
        style: ListStyle
    ) -> TextEditResult {
        let affected = affectedLineRange(in: source, selection: selectedRange)
        let lines = parsedLines(in: source.substring(with: affected))
        let bodies = lines.map { strippingListPrefix(from: indentationAndBody($0.body).body) }
        let alreadyApplied = zip(lines, bodies).allSatisfy { line, stripped in
            let body = indentationAndBody(line.body).body
            switch style {
            case .bulleted:
                return body.hasPrefix("- ") && !body.hasPrefix("- [ ] ")
                    && !body.hasPrefix("- [x] ")
            case .numbered:
                return numberedPrefixLength(in: body) != nil
            case .checklist:
                return body.hasPrefix("- [ ] ") || body.hasPrefix("- [x] ")
                    || body.hasPrefix("- [X] ")
            }
        }
        let replacement = zip(lines, bodies).enumerated().map { offset, pair in
            let (line, stripped) = pair
            let indentation = indentationAndBody(line.body).indentation
            let prefix: String
            if alreadyApplied {
                prefix = ""
            } else {
                switch style {
                case .bulleted: prefix = "- "
                case .numbered: prefix = "\(offset + 1). "
                case .checklist: prefix = "- [ ] "
                }
            }
            return indentation + prefix + stripped + line.terminator
        }.joined()
        return replacing(
            affected,
            in: source,
            with: replacement,
            selection: NSRange(
                location: affected.location, length: (replacement as NSString).length)
        )
    }

    private static func toggleLinePrefix(
        in source: NSString,
        selectedRange: NSRange,
        prefix: String
    ) -> TextEditResult {
        let affected = affectedLineRange(in: source, selection: selectedRange)
        let lines = parsedLines(in: source.substring(with: affected))
        let removesPrefix = lines.allSatisfy { line in
            indentationAndBody(line.body).body.hasPrefix(prefix)
        }
        let replacement = lines.map { line in
            let parts = indentationAndBody(line.body)
            let body =
                removesPrefix ? String(parts.body.dropFirst(prefix.count)) : prefix + parts.body
            return parts.indentation + body + line.terminator
        }.joined()
        return replacing(
            affected,
            in: source,
            with: replacement,
            selection: NSRange(
                location: affected.location, length: (replacement as NSString).length)
        )
    }

    private static func insertCodeBlock(
        in source: NSString,
        selectedRange: NSRange
    ) -> TextEditResult {
        let selected = selectedRange.length == 0 ? "code" : source.substring(with: selectedRange)
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
        let opening = leadingBreak + "```\n"
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

    private static func insertDivider(in source: NSString, selectedRange: NSRange) -> TextEditResult
    {
        let leadingBreak =
            selectedRange.location > 0 && source.character(at: selectedRange.location - 1) != 0x0A
            ? "\n" : ""
        let trailingBreak =
            NSMaxRange(selectedRange) < source.length
                && source.character(at: NSMaxRange(selectedRange)) != 0x0A ? "\n" : ""
        let replacement = leadingBreak + "---\n" + trailingBreak
        return replacing(
            selectedRange,
            in: source,
            with: replacement,
            selection: NSRange(
                location: selectedRange.location + (replacement as NSString).length, length: 0)
        )
    }

    private static func transformSelectedLines(
        in source: NSString,
        selectedRange: NSRange,
        transform: (String, Int) -> String
    ) -> TextEditResult {
        let affected = affectedLineRange(in: source, selection: selectedRange)
        let replacement = parsedLines(in: source.substring(with: affected)).enumerated().map {
            index, line in
            transform(line.body, index) + line.terminator
        }.joined()
        return replacing(
            affected,
            in: source,
            with: replacement,
            selection: NSRange(
                location: affected.location, length: (replacement as NSString).length)
        )
    }

    private static func strippingHeadingPrefix(from body: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "^#{1,6}[ \\t]+") else {
            return body
        }
        let source = body as NSString
        let range = NSRange(location: 0, length: source.length)
        guard let match = expression.firstMatch(in: body, range: range) else { return body }
        return source.substring(from: NSMaxRange(match.range))
    }

    private static func strippingListPrefix(from body: String) -> String {
        if body.hasPrefix("- [ ] ") || body.hasPrefix("- [x] ") || body.hasPrefix("- [X] ") {
            return String(body.dropFirst(6))
        }
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return String(body.dropFirst(2))
        }
        if let length = numberedPrefixLength(in: body) {
            return String(body.dropFirst(length))
        }
        return body
    }

    private static func numberedPrefixLength(in body: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: "^[0-9]+\\.[ \\t]+") else {
            return nil
        }
        let range = NSRange(location: 0, length: (body as NSString).length)
        return expression.firstMatch(in: body, range: range)?.range.length
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
