import Foundation

/// One fenced block as `MarkdownBlockDocument` recognises it.
struct MarkdownFence: Equatable {
    /// From the opening fence through the closing fence's marker, or to the end
    /// of the document when the fence is never closed.
    var range: NSRange
    /// The lines between the fences, including the last line's terminator.
    var contentRange: NSRange
    /// The lower-cased first word after the opening marker (`python`, `mermaid`).
    var label: String
    /// The closing marker itself, or `nil` for a fence still being typed.
    var closingMarkerRange: NSRange?
}

/// Finds fenced code blocks with exactly the rules the block parser uses, so
/// highlighting, Mermaid previews, and "am I in code?" checks agree with what
/// the editor styles as code.
///
/// CommonMark rules: a fence is three or more backticks or tildes, optionally
/// indented; it closes on a line holding only the same character, at least as
/// many times. An unclosed fence runs to the end of the document.
enum MarkdownFenceScanner {
    static func fences(in source: String) -> [MarkdownFence] {
        let text = source as NSString
        var fences: [MarkdownFence] = []
        var open: (marker: String, label: String, start: Int, contentStart: Int)?
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let body = bodyRange(of: line, in: text)
            let value = text.substring(with: body)
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let current = open {
                if closes(trimmed, opening: current.marker) {
                    let markerStart =
                        body.location
                        + (value as NSString).range(of: String(current.marker.first ?? "`"))
                        .location
                    let markerLength = trimmed.prefix { $0 == current.marker.first }.utf16.count
                    let marker = NSRange(location: markerStart, length: markerLength)
                    fences.append(
                        MarkdownFence(
                            range: NSRange(
                                location: current.start,
                                length: NSMaxRange(marker) - current.start
                            ),
                            contentRange: NSRange(
                                location: current.contentStart,
                                length: line.location - current.contentStart
                            ),
                            label: current.label,
                            closingMarkerRange: marker
                        ))
                    open = nil
                }
            } else if let opening = openingMarker(in: trimmed) {
                open = (opening.marker, opening.label, body.location, NSMaxRange(line))
            }
            location = NSMaxRange(line)
        }
        if let current = open {
            fences.append(
                MarkdownFence(
                    range: NSRange(location: current.start, length: text.length - current.start),
                    contentRange: NSRange(
                        location: min(current.contentStart, text.length),
                        length: max(text.length - current.contentStart, 0)
                    ),
                    label: current.label,
                    closingMarkerRange: nil
                ))
        }
        return fences
    }

    private static func openingMarker(in trimmed: String) -> (marker: String, label: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let marker = String(trimmed.prefix { $0 == first })
        guard marker.count >= 3 else { return nil }
        let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not itself contain a backtick;
        // otherwise ``` `code` ``` inline would read as a fence.
        if first == "`", info.contains("`") { return nil }
        let label = info.prefix { !$0.isWhitespace }.lowercased()
        return (marker, label)
    }

    private static func closes(_ trimmed: String, opening: String) -> Bool {
        guard let character = opening.first else { return false }
        let marker = trimmed.prefix { $0 == character }
        return marker.count >= opening.count
            && trimmed.dropFirst(marker.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func bodyRange(of line: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location, [10, 13].contains(text.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }
}
