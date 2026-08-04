import Foundation

enum SyntaxHighlightRange {
    static let marginLineCount = 200

    static func around(
        _ visibleRange: NSRange,
        in source: String,
        marginLines: Int = marginLineCount
    ) -> NSRange {
        let text = source as NSString
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let clampedLocation = min(max(visibleRange.location, 0), text.length)
        let clampedEnd = min(max(NSMaxRange(visibleRange), clampedLocation), text.length)
        var start = clampedLocation
        var end = clampedEnd

        for _ in 0..<max(marginLines, 0) {
            guard start > 0 else { break }
            let precedingLine = text.lineRange(
                for: NSRange(location: start - 1, length: 0)
            )
            guard precedingLine.location < start else { break }
            start = precedingLine.location
        }

        for _ in 0..<max(marginLines, 0) {
            guard end < text.length else { break }
            let followingLine = text.lineRange(
                for: NSRange(location: end, length: 0)
            )
            let followingEnd = NSMaxRange(followingLine)
            guard followingEnd > end else { break }
            end = followingEnd
        }

        return NSRange(location: start, length: end - start)
    }
}
