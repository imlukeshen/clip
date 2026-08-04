import AppKit
import CoreModel
import Foundation
import TextEngine

/// Selection-aware copy and export transformations for the native text editor.
public enum TextSnippetOperations {
    public static func copyWithLineNumbers(
        in text: String,
        selectedRange: NSRange
    ) -> String? {
        guard let selection = selection(in: text, range: selectedRange) else { return nil }
        var lines = normalizedLines(selection.text)
        if selection.text.hasSuffix("\n") || selection.text.hasSuffix("\r") {
            lines.removeLast()
        }
        let finalLine = selection.firstLine + max(lines.count - 1, 0)
        let width = max(String(finalLine).count, 1)
        return lines.enumerated().map { offset, line in
            let number = String(selection.firstLine + offset)
            return String(repeating: " ", count: width - number.count) + number + " │ " + line
        }.joined(separator: "\n")
    }

    public static func annotatedSelection(
        in text: String,
        selectedRange: NSRange,
        fileName: String
    ) -> String? {
        guard let selection = selection(in: text, range: selectedRange) else { return nil }
        let suffix =
            selection.firstLine == selection.lastLine
            ? "\(selection.firstLine)" : "\(selection.firstLine)–\(selection.lastLine)"
        return "\(fileName):\(suffix)\n\(selection.text)"
    }

    public static func wrappingSelectionInCodeFence(
        in text: String,
        selectedRange: NSRange,
        language: LanguageID
    ) -> TextEditResult? {
        guard let selection = selection(in: text, range: selectedRange) else { return nil }
        let delimiter = String(
            repeating: "`",
            count: max(longestBacktickRun(in: selection.text) + 1, 3)
        )
        let languageTag = language == .plainText ? "" : language.rawValue
        let closingBreak =
            selection.text.hasSuffix("\n") || selection.text.hasSuffix("\r") ? "" : "\n"
        let opening = delimiter + languageTag + "\n"
        let replacement = opening + selection.text + closingBreak + delimiter
        let source = text as NSString
        return TextEditResult(
            text: source.replacingCharacters(in: selection.range, with: replacement),
            selectedRange: NSRange(
                location: selection.range.location + opening.utf16.count,
                length: selection.text.utf16.count
            )
        )
    }

    @MainActor
    public static func richTextData(
        from attributedString: NSAttributedString,
        backgroundColor: NSColor
    ) -> Data? {
        guard attributedString.length > 0 else { return nil }
        let value = NSMutableAttributedString(attributedString: attributedString)
        value.addAttribute(
            .backgroundColor,
            value: backgroundColor,
            range: NSRange(location: 0, length: value.length)
        )
        return try? value.data(
            from: NSRange(location: 0, length: value.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    @MainActor
    public static func htmlFragment(
        from attributedString: NSAttributedString,
        backgroundColor: NSColor
    ) -> String {
        var content = ""
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let value = (attributedString.string as NSString).substring(with: range)
            var styles: [String] = []
            if let color = attributes[.foregroundColor] as? NSColor,
                let color = cssColor(color)
            {
                styles.append("color:\(color)")
            }
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { styles.append("font-weight:600") }
                if traits.contains(.italicFontMask) { styles.append("font-style:italic") }
            }
            let escaped = escapeHTML(value)
            if styles.isEmpty {
                content += escaped
            } else {
                content += "<span style=\"\(styles.joined(separator: ";"))\">\(escaped)</span>"
            }
        }
        let background = cssColor(backgroundColor) ?? "#111315"
        return """
            <pre style="margin:0;padding:16px;overflow:auto;border-radius:10px;background:\(background);font:13px ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;line-height:1.5;white-space:pre-wrap"><code>\(content)</code></pre>
            """
    }

    @MainActor
    public static func attributedString(
        source: String,
        tokens: [SyntaxToken]
    ) -> NSAttributedString {
        let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let value = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: baseFont,
                .foregroundColor: NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.18, alpha: 1),
            ]
        )
        let colors: [SyntaxTokenKind: NSColor] = [
            .keyword: NSColor(calibratedRed: 0.51, green: 0.22, blue: 0.75, alpha: 1),
            .string: NSColor(calibratedRed: 0.07, green: 0.39, blue: 0.16, alpha: 1),
            .comment: NSColor(calibratedRed: 0.43, green: 0.47, blue: 0.51, alpha: 1),
            .number: NSColor(calibratedRed: 0.02, green: 0.31, blue: 0.68, alpha: 1),
            .type: NSColor(calibratedRed: 0.58, green: 0.22, blue: 0.00, alpha: 1),
            .function: NSColor(calibratedRed: 0.02, green: 0.31, blue: 0.68, alpha: 1),
            .property: NSColor(calibratedRed: 0.72, green: 0.11, blue: 0.16, alpha: 1),
            .tag: NSColor(calibratedRed: 0.33, green: 0.24, blue: 0.63, alpha: 1),
            .heading: NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.18, alpha: 1),
            .emphasis: NSColor(calibratedRed: 0.33, green: 0.36, blue: 0.40, alpha: 1),
            .link: NSColor(calibratedRed: 0.02, green: 0.31, blue: 0.68, alpha: 1),
            .escape: NSColor(calibratedRed: 0.02, green: 0.31, blue: 0.68, alpha: 1),
            .operator: NSColor(calibratedRed: 0.43, green: 0.47, blue: 0.51, alpha: 1),
        ]
        for token in tokens.sorted(by: {
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.range.location < $1.range.location
        }) {
            let range = NSIntersectionRange(
                token.range,
                NSRange(location: 0, length: value.length)
            )
            guard range.length > 0, let color = colors[token.kind] else { continue }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if token.kind == .heading || token.kind == .emphasis {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            }
            value.addAttributes(attributes, range: range)
        }
        return value
    }

    @MainActor
    public static func standaloneHTML(
        title: String,
        attributedString: NSAttributedString
    ) -> String {
        let fragment = htmlFragment(
            from: attributedString,
            backgroundColor: NSColor(calibratedWhite: 0.97, alpha: 1)
        )
        return """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
              <title>\(escapeHTML(title))</title>
            </head>
            <body style="margin:0;padding:24px;background:#ffffff">\(fragment)</body>
            </html>
            """
    }

    private struct Selection {
        var range: NSRange
        var text: String
        var firstLine: Int
        var lastLine: Int
    }

    private static func selection(in text: String, range requestedRange: NSRange) -> Selection? {
        let source = text as NSString
        let location = min(max(requestedRange.location, 0), source.length)
        let length = min(max(requestedRange.length, 0), source.length - location)
        guard length > 0 else { return nil }
        let range = NSRange(location: location, length: length)
        return Selection(
            range: range,
            text: source.substring(with: range),
            firstLine: lineNumber(at: location, in: source),
            lastLine: lineNumber(at: max(NSMaxRange(range) - 1, location), in: source)
        )
    }

    private static func lineNumber(at offset: Int, in source: NSString) -> Int {
        var line = 1
        var index = 0
        while index < min(offset, source.length) {
            let character = source.character(at: index)
            if character == 0x0D {
                if index + 1 < offset, source.character(at: index + 1) == 0x0A {
                    index += 1
                }
                line += 1
            } else if character == 0x0A {
                line += 1
            }
            index += 1
        }
        return line
    }

    private static func normalizedLines(_ value: String) -> [String] {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func longestBacktickRun(in value: String) -> Int {
        var longest = 0
        var current = 0
        for character in value {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    @MainActor
    private static func cssColor(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
