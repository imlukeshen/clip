import Foundation

/// Pure text transformations shared by the AppKit editor and regression tests.
public enum TextEditingOperations {
    /// A vertical direction used when moving the selected lines.
    public enum LineDirection: Sendable {
        /// Moves the selection toward the beginning of the document.
        case up
        /// Moves the selection toward the end of the document.
        case down
    }

    /// Adds or removes the language's comment delimiters on every selected line.
    public static func toggleComment(
        in text: String,
        selectedRange: NSRange,
        prefix: String,
        suffix: String = ""
    ) -> TextEditResult {
        let source = text as NSString
        let range = affectedLineRange(in: source, selection: selectedRange)
        let lines = parsedLines(in: source.substring(with: range))
        let nonempty = lines.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
        let removesComments =
            !nonempty.isEmpty
            && nonempty.allSatisfy { line in
                let body = line.body as NSString
                let first = firstNonWhitespaceOffset(in: body)
                let remainder = body.substring(from: first)
                return remainder.hasPrefix(prefix)
                    && (suffix.isEmpty || remainder.hasSuffix(suffix))
            }
        let transformed = lines.map { line -> String in
            guard !line.body.trimmingCharacters(in: .whitespaces).isEmpty else {
                return line.body + line.terminator
            }
            let body = line.body as NSString
            let first = firstNonWhitespaceOffset(in: body)
            let leading = body.substring(to: first)
            let remainder = body.substring(from: first)
            if removesComments, remainder.hasPrefix(prefix) {
                var uncommented = String(remainder.dropFirst(prefix.count))
                if uncommented.hasPrefix(" ") { uncommented.removeFirst() }
                if !suffix.isEmpty, uncommented.hasSuffix(suffix) {
                    uncommented.removeLast(suffix.count)
                    if uncommented.hasSuffix(" ") { uncommented.removeLast() }
                }
                return leading + uncommented + line.terminator
            }
            let closing = suffix.isEmpty ? "" : " " + suffix
            return leading + prefix + " " + remainder + closing + line.terminator
        }.joined()
        return replacing(range, in: source, with: transformed)
    }

    /// Inserts the configured number of spaces before every selected line.
    public static func indent(
        in text: String,
        selectedRange: NSRange,
        width: Int
    ) -> TextEditResult {
        transformSelectedLines(in: text, selectedRange: selectedRange) { line in
            String(repeating: " ", count: max(width, 1)) + line
        }
    }

    /// Removes one tab or up to the configured number of spaces from selected lines.
    public static func outdent(
        in text: String,
        selectedRange: NSRange,
        width: Int
    ) -> TextEditResult {
        transformSelectedLines(in: text, selectedRange: selectedRange) { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let removable = line.prefix(max(width, 1)).prefix { $0 == " " }.count
            return String(line.dropFirst(removable))
        }
    }

    /// Copies every selected line directly below the original lines.
    public static func duplicateLine(
        in text: String,
        selectedRange: NSRange
    ) -> TextEditResult {
        let source = text as NSString
        let range = affectedLineRange(in: source, selection: selectedRange)
        var duplicate = source.substring(with: range)
        if !duplicate.hasSuffix("\n") && !duplicate.hasSuffix("\r") {
            duplicate = "\n" + duplicate
        }
        let updated = source.replacingCharacters(
            in: NSRange(location: NSMaxRange(range), length: 0),
            with: duplicate
        )
        return TextEditResult(
            text: updated,
            selectedRange: NSRange(location: NSMaxRange(range), length: duplicate.utf16.count)
        )
    }

    /// Moves every selected line one position in the requested direction.
    public static func moveLine(
        in text: String,
        selectedRange: NSRange,
        direction: LineDirection
    ) -> TextEditResult {
        let source = text as NSString
        let range = affectedLineRange(in: source, selection: selectedRange)
        switch direction {
        case .up:
            guard range.location > 0 else {
                return TextEditResult(text: text, selectedRange: selectedRange)
            }
            let previous = source.lineRange(
                for: NSRange(location: range.location - 1, length: 0)
            )
            let currentLine = splitFinalTerminator(source.substring(with: range))
            let previousLine = splitFinalTerminator(source.substring(with: previous))
            let replacement =
                currentLine.body + previousLine.terminator + previousLine.body
                + currentLine.terminator
            let combined = NSRange(
                location: previous.location,
                length: previous.length + range.length
            )
            let updated = source.replacingCharacters(in: combined, with: replacement)
            return TextEditResult(
                text: updated,
                selectedRange: NSRange(
                    location: max(selectedRange.location - previous.length, previous.location),
                    length: selectedRange.length
                )
            )
        case .down:
            guard NSMaxRange(range) < source.length else {
                return TextEditResult(text: text, selectedRange: selectedRange)
            }
            let next = source.lineRange(
                for: NSRange(location: NSMaxRange(range), length: 0)
            )
            let currentLine = splitFinalTerminator(source.substring(with: range))
            let nextLine = splitFinalTerminator(source.substring(with: next))
            let replacement =
                nextLine.body + currentLine.terminator + currentLine.body + nextLine.terminator
            let combined = NSRange(location: range.location, length: range.length + next.length)
            let updated = source.replacingCharacters(in: combined, with: replacement)
            return TextEditResult(
                text: updated,
                selectedRange: NSRange(
                    location: selectedRange.location + nextLine.body.utf16.count
                        + currentLine.terminator.utf16.count,
                    length: selectedRange.length
                )
            )
        }
    }

    /// Removes spaces and tabs immediately before line endings and end of file.
    public static func trimmingTrailingWhitespace(in text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var whitespaceStart: Int?
        for byte in text.utf8 {
            if byte == 0x20 || byte == 0x09 {
                whitespaceStart = whitespaceStart ?? bytes.count
                bytes.append(byte)
            } else {
                if byte == 0x0A || byte == 0x0D, let whitespaceStart {
                    bytes.removeSubrange(whitespaceStart...)
                }
                whitespaceStart = nil
                bytes.append(byte)
            }
        }
        if let whitespaceStart {
            bytes.removeSubrange(whitespaceStart...)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func transformSelectedLines(
        in text: String,
        selectedRange: NSRange,
        transform: (String) -> String
    ) -> TextEditResult {
        let source = text as NSString
        let range = affectedLineRange(in: source, selection: selectedRange)
        let replacement = parsedLines(in: source.substring(with: range)).map { line in
            transform(line.body) + line.terminator
        }.joined()
        return replacing(range, in: source, with: replacement)
    }

    private static func replacing(
        _ range: NSRange,
        in source: NSString,
        with replacement: String
    ) -> TextEditResult {
        TextEditResult(
            text: source.replacingCharacters(in: range, with: replacement),
            selectedRange: NSRange(location: range.location, length: replacement.utf16.count)
        )
    }

    private static func affectedLineRange(
        in source: NSString,
        selection: NSRange
    ) -> NSRange {
        let location = min(max(selection.location, 0), source.length)
        let available = max(source.length - location, 0)
        var length = min(max(selection.length, 0), available)
        if length > 0, location + length < source.length {
            let previous = source.substring(
                with: NSRange(location: location + length - 1, length: 1)
            )
            if previous == "\n" || previous == "\r" { length -= 1 }
        }
        return source.lineRange(for: NSRange(location: location, length: length))
    }

    private static func firstNonWhitespaceOffset(in line: NSString) -> Int {
        var offset = 0
        while offset < line.length {
            let scalar = line.character(at: offset)
            guard scalar == 0x20 || scalar == 0x09 else { break }
            offset += 1
        }
        return offset
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

    private static func splitFinalTerminator(_ text: String) -> (body: String, terminator: String) {
        if text.hasSuffix("\r\n") {
            return (String(text.dropLast(2)), "\r\n")
        }
        if text.hasSuffix("\r") || text.hasSuffix("\n") {
            return (String(text.dropLast()), String(text.suffix(1)))
        }
        return (text, "")
    }
}
