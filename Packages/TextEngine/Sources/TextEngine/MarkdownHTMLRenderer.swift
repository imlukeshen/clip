import Foundation
import Markdown

/// The destination controls how relative images are represented in rendered HTML.
public enum MarkdownRenderDestination: Sendable {
    /// Relative images use Clip's scoped WebKit URL scheme.
    case preview
    /// Relative images are embedded so the exported document remains self-contained.
    case export(baseDirectory: URL?)
}

/// Safe, self-contained HTML produced from Markdown.
public struct MarkdownRenderResult: Sendable, Equatable {
    public let html: String
    public let sourceBlockLines: [Int]
    public let blockedResourceCount: Int

    public init(html: String, sourceBlockLines: [Int], blockedResourceCount: Int) {
        self.html = html
        self.sourceBlockLines = sourceBlockLines
        self.blockedResourceCount = blockedResourceCount
    }
}

/// Renders GFM Markdown without admitting document-authored HTML or executable code.
public enum MarkdownHTMLRenderer {
    public static func render(
        _ source: String,
        destination: MarkdownRenderDestination = .preview
    ) -> MarkdownRenderResult {
        let prepared = MarkdownPreprocessor(source: source).run()
        let document = Document(parsing: prepared.source)
        var formatter = SafeMarkdownFormatter(
            math: prepared.math,
            footnoteReferences: prepared.references,
            destination: destination
        )
        formatter.visit(document)

        if !prepared.footnotes.isEmpty {
            formatter.appendFootnotes(prepared.footnotes)
        }

        let body = formatter.result
        return MarkdownRenderResult(
            html: MarkdownPage.document(body: body),
            sourceBlockLines: formatter.sourceBlockLines,
            blockedResourceCount: formatter.blockedResourceCount
        )
    }
}

/// Resolves only raster images below the Markdown file's own directory.
public enum MarkdownLocalResourceResolver {
    private static let allowedExtensions: Set<String> = [
        "gif", "heic", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]

    public static func resolve(_ relativePath: String, below baseDirectory: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
            URL(string: relativePath)?.scheme == nil
        else { return nil }

        let pathWithoutSuffix =
            relativePath
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let decoded = String(pathWithoutSuffix).removingPercentEncoding else { return nil }

        let base = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate =
            base
            .appendingPathComponent(decoded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path.hasPrefix(basePath),
            allowedExtensions.contains(candidate.pathExtension.lowercased()),
            FileManager.default.fileExists(atPath: candidate.path)
        else { return nil }
        return candidate
    }

    public static func previewURL(for relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
            URL(string: relativePath)?.scheme == nil,
            let encoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "clip-local://asset/\(encoded)")
    }
}

private struct PreparedMarkdown {
    let source: String
    let math: [MathExpression]
    let references: [FootnoteReference]
    let footnotes: [FootnoteDefinition]
}

private struct MathExpression {
    let token: String
    let tex: String
    let isDisplay: Bool
}

private struct FootnoteReference {
    let token: String
    let label: String
    let ordinal: Int
}

private struct FootnoteDefinition {
    let label: String
    let sourceLine: Int
    let markdown: String
}

private struct MarkdownPreprocessor {
    let source: String

    func run() -> PreparedMarkdown {
        let extracted = extractFootnotes(from: source)
        var working = extracted.source
        var references: [FootnoteReference] = []
        var referenceCounts: [String: Int] = [:]
        var replacements: [(range: Range<String.Index>, token: String)] = []

        let protected = protectedCodeRanges(in: working)
        let referencePattern = try? NSRegularExpression(pattern: #"\[\^([^\]\n]+)\]"#)
        if let matches = referencePattern?.matches(
            in: working,
            range: NSRange(location: 0, length: (working as NSString).length)
        ) {
            for match in matches
            where !protected.contains(where: { $0.intersection(match.range) != nil }) {
                guard let labelRange = Range(match.range(at: 1), in: working),
                    let fullRange = Range(match.range, in: working)
                else { continue }
                let label = String(working[labelRange])
                guard extracted.definitions.contains(where: { $0.label == label }) else { continue }
                let ordinal = (referenceCounts[label] ?? 0) + 1
                referenceCounts[label] = ordinal
                let token = "CLIPFNREF\(references.count)TOKEN"
                references.append(FootnoteReference(token: token, label: label, ordinal: ordinal))
                replacements.append((range: fullRange, token: token))
            }
            for replacement in replacements.reversed() {
                working.replaceSubrange(replacement.range, with: replacement.token)
            }
        }

        var math: [MathExpression] = []
        working = replacingMath(in: working, display: true, expressions: &math)
        working = replacingMath(in: working, display: false, expressions: &math)
        return PreparedMarkdown(
            source: working,
            math: math,
            references: references,
            footnotes: extracted.definitions,
        )
    }

    private func extractFootnotes(from source: String) -> (
        source: String, definitions: [FootnoteDefinition]
    ) {
        var lines = source.components(separatedBy: "\n")
        var definitions: [FootnoteDefinition] = []
        let pattern = try? NSRegularExpression(pattern: #"^[ \t]{0,3}\[\^([^\]]+)\]:[ \t]*(.*)$"#)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let match = pattern?.firstMatch(in: line, range: range),
                let labelRange = Range(match.range(at: 1), in: line),
                let contentRange = Range(match.range(at: 2), in: line)
            else {
                index += 1
                continue
            }

            let start = index
            let label = String(line[labelRange])
            var content = [String(line[contentRange])]
            lines[index] = ""
            index += 1
            while index < lines.count {
                let continuation = lines[index]
                if continuation.hasPrefix("    ") {
                    content.append(String(continuation.dropFirst(4)))
                    lines[index] = ""
                    index += 1
                } else if continuation.hasPrefix("\t") {
                    content.append(String(continuation.dropFirst()))
                    lines[index] = ""
                    index += 1
                } else if continuation.isEmpty {
                    content.append("")
                    lines[index] = ""
                    index += 1
                } else {
                    break
                }
            }
            definitions.append(
                FootnoteDefinition(
                    label: label,
                    sourceLine: start + 1,
                    markdown: content.joined(separator: "\n").trimmingCharacters(
                        in: .whitespacesAndNewlines)
                )
            )
        }
        return (lines.joined(separator: "\n"), definitions)
    }

    private func replacingMath(
        in source: String,
        display: Bool,
        expressions: inout [MathExpression]
    ) -> String {
        var result = source
        let pattern =
            display
            ? #"(?s)(?<!\\)\$\$(.+?)(?<!\\)\$\$"#
            : #"(?<![\\$])\$([^$\n]+?)(?<!\\)\$(?!\$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let protected = protectedCodeRanges(in: source)
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        )
        for match in matches.reversed()
        where !protected.contains(where: { $0.intersection(match.range) != nil }) {
            guard let texRange = Range(match.range(at: 1), in: result),
                let fullRange = Range(match.range, in: result)
            else { continue }
            let tex = String(result[texRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tex.isEmpty else { continue }
            let token = "CLIPMATH\(display ? "BLOCK" : "INLINE")\(expressions.count)TOKEN"
            let newlineCount = result[fullRange].filter { $0 == "\n" }.count
            expressions.append(MathExpression(token: token, tex: tex, isDisplay: display))
            result.replaceSubrange(
                fullRange, with: token + String(repeating: "\n", count: newlineCount))
        }
        return result
    }

    private func protectedCodeRanges(in source: String) -> [NSRange] {
        let nsSource = source as NSString
        let full = NSRange(location: 0, length: nsSource.length)
        let patterns = [
            #"(?ms)^ {0,3}```[^\n]*\n.*?^ {0,3}```[ \t]*$"#,
            #"(?ms)^ {0,3}~~~[^\n]*\n.*?^ {0,3}~~~[ \t]*$"#,
            #"`+[^`\n]*`+"#,
        ]
        return patterns.flatMap { pattern in
            (try? NSRegularExpression(pattern: pattern))?.matches(in: source, range: full).map(
                \.range) ?? []
        }
    }
}

private struct SafeMarkdownFormatter: MarkupWalker {
    var result = ""
    var sourceBlockLines: [Int] = []
    var blockedResourceCount = 0

    private let math: [MathExpression]
    private let footnoteReferences: [FootnoteReference]
    private let destination: MarkdownRenderDestination
    private var linkDepth = 0
    private var tableAlignments: [Table.ColumnAlignment?] = []
    private var tableColumn = 0
    private var isTableHead = false

    init(
        math: [MathExpression],
        footnoteReferences: [FootnoteReference],
        destination: MarkdownRenderDestination
    ) {
        self.math = math
        self.footnoteReferences = footnoteReferences
        self.destination = destination
    }

    mutating func visitDocument(_ document: Document) {
        for child in document.children {
            let line = child.range?.lowerBound.line ?? 1
            sourceBlockLines.append(line)
            result += #"<section class="source-block" data-source-line="\#(line)">"#
            visit(child)
            result += "</section>\n"
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language?.lowercased() ?? ""
        let languageClass =
            language.isEmpty ? "" : #" class="language-\#(htmlAttribute(language))""#
        result += "<pre><code\(languageClass)>"
        result += FencedCodeHighlighter.render(codeBlock.code, language: language)
        result += "</code></pre>\n"
    }

    mutating func visitCustomBlock(_ customBlock: CustomBlock) {
        descendInto(customBlock)
    }

    mutating func visitHeading(_ heading: Heading) {
        result += "<h\(heading.level)>"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        appendBlockedHTMLPlaceholderIfNeeded(html.rawHTML)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        let taskClass = listItem.checkbox == nil ? "" : #" class="task-list-item""#
        result += "<li\(taskClass)>"
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            result += #"<input type="checkbox" disabled\#(checked) aria-label="Task status"> "#
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex == 1 ? "" : #" start="\#(orderedList.startIndex)""#
        result += "<ol\(start)>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitBlockDirective(_ blockDirective: BlockDirective) {
        descendInto(blockDirective)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(htmlText(inlineCode.code))</code>"
    }

    mutating func visitCustomInline(_ customInline: CustomInline) {}

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        result += "<del>"
        descendInto(strikethrough)
        result += "</del>"
    }

    mutating func visitImage(_ image: Image) {
        guard let source = image.source, let rendered = renderImageSource(source) else {
            appendBlockedResourcePlaceholder()
            return
        }
        let title = image.title.map { #" title="\#(htmlAttribute($0))""# } ?? ""
        result += #"<img src="\#(htmlAttribute(rendered))" alt="Image"\#(title)>"#
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        appendBlockedHTMLPlaceholderIfNeeded(inlineHTML.rawHTML)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLink(_ link: Link) {
        guard let destination = safeLink(link.destination) else {
            descendInto(link)
            return
        }
        result += #"<a href="\#(htmlAttribute(destination))">"#
        linkDepth += 1
        descendInto(link)
        linkDepth -= 1
        result += "</a>"
    }

    mutating func visitText(_ text: Text) {
        result += renderText(text.string)
    }

    mutating func visitTable(_ table: Table) {
        let previous = tableAlignments
        tableAlignments = table.columnAlignments
        result += "<div class=\"table-scroll\"><table>\n"
        descendInto(table)
        result += "</table></div>\n"
        tableAlignments = previous
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        isTableHead = true
        tableColumn = 0
        result += "<thead><tr>\n"
        descendInto(tableHead)
        result += "</tr></thead>\n"
        isTableHead = false
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        tableColumn = 0
        result += "<tr>"
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        let tag = isTableHead ? "th" : "td"
        let alignment: String
        if tableColumn < tableAlignments.count, let value = tableAlignments[tableColumn] {
            alignment = #" style="text-align:\#(value)""#
        } else {
            alignment = ""
        }
        tableColumn += 1
        result += "<\(tag)\(alignment)>"
        descendInto(tableCell)
        result += "</\(tag)>"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        if let destination = symbolLink.destination {
            result += "<code>\(htmlText(destination))</code>"
        }
    }

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) {
        descendInto(attributes)
    }

    mutating func appendFootnotes(_ footnotes: [FootnoteDefinition]) {
        result += #"<section class="footnotes" aria-label="Footnotes"><hr><ol>"#
        for footnote in footnotes {
            let safeID = identifier(footnote.label)
            result +=
                #"<li id="fn-\#(safeID)" class="source-block" data-source-line="\#(footnote.sourceLine)">"#
            let document = Document(parsing: footnote.markdown)
            var nested = SafeMarkdownFormatter(
                math: [], footnoteReferences: [], destination: destination)
            nested.visit(document)
            result += nested.result
            result +=
                ##" <a class="footnote-backref" href="#fnref-\##(safeID)-1" aria-label="Back to reference">↩</a></li>"##
            blockedResourceCount += nested.blockedResourceCount
        }
        result += "</ol></section>"
    }

    private mutating func appendBlockedHTMLPlaceholderIfNeeded(_ rawHTML: String) {
        guard rawHTML.range(of: "<img", options: [.caseInsensitive]) != nil else { return }
        appendBlockedResourcePlaceholder()
    }

    private mutating func appendBlockedResourcePlaceholder() {
        blockedResourceCount += 1
        result +=
            #"<span class="blocked-resource" role="note">Remote or unsafe image blocked</span>"#
    }

    private mutating func renderText(_ value: String) -> String {
        var rendered = ""
        var cursor = value.startIndex
        let tokens = tokenMatches(in: value)
        for match in tokens {
            rendered += renderAutolinks(String(value[cursor..<match.range.lowerBound]))
            switch match.kind {
            case .math(let expression):
                let displayClass = expression.isDisplay ? " math-display" : ""
                rendered +=
                    #"<span class="math\#(displayClass)" data-tex="\#(htmlAttribute(expression.tex))">\#(htmlText(expression.tex))</span>"#
            case .footnote(let reference):
                let safeID = identifier(reference.label)
                rendered +=
                    ##"<sup class="footnote-ref" id="fnref-\##(safeID)-\##(reference.ordinal)"><a href="#fn-\##(safeID)">\##(htmlText(reference.label))</a></sup>"##
            }
            cursor = match.range.upperBound
        }
        rendered += renderAutolinks(String(value[cursor...]))
        return rendered
    }

    private func renderAutolinks(_ value: String) -> String {
        guard linkDepth == 0,
            let expression = try? NSRegularExpression(
                pattern: #"(?i)(?<![\w=\"'])((?:https?://|www\.)[^\s<>]+)"#
            )
        else { return htmlText(value) }
        let nsValue = value as NSString
        let matches = expression.matches(
            in: value,
            range: NSRange(location: 0, length: nsValue.length)
        )
        guard !matches.isEmpty else { return htmlText(value) }
        var output = ""
        var location = 0
        for match in matches {
            output += htmlText(
                nsValue.substring(
                    with: NSRange(location: location, length: match.range.location - location)))
            var label = nsValue.substring(with: match.range)
            var suffix = ""
            while let last = label.last, ".,;:!?)]".contains(last) {
                suffix.insert(label.removeLast(), at: suffix.startIndex)
            }
            let href = label.lowercased().hasPrefix("www.") ? "https://\(label)" : label
            output += #"<a href="\#(htmlAttribute(href))">\#(htmlText(label))</a>"#
            output += htmlText(suffix)
            location = match.range.location + match.range.length
        }
        output += htmlText(nsValue.substring(from: location))
        return output
    }

    private func tokenMatches(in value: String) -> [TokenMatch] {
        var matches: [TokenMatch] = []
        for expression in math {
            if let range = value.range(of: expression.token) {
                matches.append(TokenMatch(range: range, kind: .math(expression)))
            }
        }
        for reference in footnoteReferences {
            if let range = value.range(of: reference.token) {
                matches.append(TokenMatch(range: range, kind: .footnote(reference)))
            }
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private mutating func renderImageSource(_ source: String) -> String? {
        if let url = URL(string: source), url.scheme != nil { return nil }
        switch destination {
        case .preview:
            return MarkdownLocalResourceResolver.previewURL(for: source)?.absoluteString
        case .export(let baseDirectory):
            guard let baseDirectory,
                let url = MarkdownLocalResourceResolver.resolve(source, below: baseDirectory),
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                data.count <= 20 * 1_024 * 1_024,
                let mime = imageMIMEType(for: url.pathExtension)
            else { return nil }
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
    }

    private func safeLink(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("#") { return value }
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        return value
    }
}

private struct TokenMatch {
    enum Kind {
        case math(MathExpression)
        case footnote(FootnoteReference)
    }

    let range: Range<String.Index>
    let kind: Kind
}

private enum FencedCodeHighlighter {
    static func render(_ source: String, language: String) -> String {
        let comment =
            ["bash", "python", "ruby", "shell", "yaml", "yml"].contains(language)
            ? #"#[^\n]*"# : #"//[^\n]*|/\*[\s\S]*?\*/"#
        let keywords = keywordPattern(for: language)
        let pattern =
            "(\(comment))|(\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')|(\\b(?:\(keywords))\\b)|(\\b(?:0x[0-9a-fA-F]+|\\d+(?:\\.\\d+)?)\\b)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return htmlText(source)
        }
        let nsSource = source as NSString
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        var output = ""
        var location = 0
        for match in matches {
            output += htmlText(
                nsSource.substring(
                    with: NSRange(location: location, length: match.range.location - location)))
            let kind: String
            if match.range(at: 1).location != NSNotFound {
                kind = "comment"
            } else if match.range(at: 2).location != NSNotFound {
                kind = "string"
            } else if match.range(at: 3).location != NSNotFound {
                kind = "keyword"
            } else {
                kind = "number"
            }
            output +=
                #"<span class="syntax-\#(kind)">\#(htmlText(nsSource.substring(with: match.range)))</span>"#
            location = match.range.location + match.range.length
        }
        output += htmlText(nsSource.substring(from: location))
        return output
    }

    private static func keywordPattern(for language: String) -> String {
        switch language {
        case "swift":
            "actor|as|async|await|case|class|enum|extension|func|guard|if|import|let|protocol|return|struct|switch|throw|throws|try|var|where"
        case "javascript", "js", "typescript", "ts":
            "async|await|break|case|class|const|else|export|extends|for|function|if|import|interface|let|new|return|switch|throw|try|type|var|while"
        case "python", "py":
            "and|as|async|await|break|class|continue|def|elif|else|except|False|finally|for|from|if|import|in|is|lambda|None|not|or|pass|raise|return|True|try|while|with|yield"
        case "rust":
            "as|async|await|break|const|continue|crate|else|enum|extern|false|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|true|type|unsafe|use|where|while"
        default:
            "break|case|class|const|continue|default|do|else|enum|false|for|func|function|if|import|let|nil|null|private|public|return|static|struct|switch|throw|true|try|var|while"
        }
    }
}

private enum MarkdownPage {
    static func document(body: String) -> String {
        let katexCSS = MarkdownPreviewAssets.katexCSS
        let katexJS = MarkdownPreviewAssets.katexJavaScript
        return """
            <!doctype html>
            <html><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src clip-local: data:; style-src 'unsafe-inline'; font-src data:; script-src 'unsafe-inline'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none';">
            <style>\(katexCSS)</style>
            <style>
            :root{color-scheme:light dark;--bg:#ffffff;--fg:#202124;--muted:#6e737a;--line:#e1e4e8;--panel:#f6f7f8;--accent:#2878c7;--code-keyword:#7c3aed;--code-string:#16803d;--code-comment:#777d85;--code-number:#b45309}
            @media(prefers-color-scheme:dark){:root{--bg:#111315;--fg:#eceef0;--muted:#969ca4;--line:#30343a;--panel:#1b1e22;--accent:#6cb4ff;--code-keyword:#c4a7ff;--code-string:#72d68b;--code-comment:#8b929c;--code-number:#ffbd6b}}
            *{box-sizing:border-box}html{background:var(--bg)}body{margin:0 auto;max-width:820px;padding:40px 44px 96px;background:var(--bg);color:var(--fg);font:15.5px/1.62 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;-webkit-font-smoothing:antialiased}
            .source-block{scroll-margin-top:22px;min-height:1px}h1,h2,h3,h4,h5,h6{line-height:1.22;margin:1.5em 0 .58em;letter-spacing:-.018em}h1{font-size:2em;border-bottom:1px solid var(--line);padding-bottom:.32em}h2{font-size:1.5em;border-bottom:1px solid var(--line);padding-bottom:.28em}h3{font-size:1.2em}p{margin:.72em 0}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}blockquote{margin:1em 0;padding:.1em 1em;border-left:3px solid var(--line);color:var(--muted)}hr{height:1px;border:0;background:var(--line);margin:2em 0}
            ul,ol{padding-left:1.65em}.task-list-item{list-style:none;margin-left:-1.25em}.task-list-item input{margin-right:.42em;accent-color:var(--accent)}code{font:13px/1.55 ui-monospace,"SFMono-Regular",Menlo,monospace;background:var(--panel);border-radius:5px;padding:.14em .34em}pre{overflow:auto;margin:1em 0;padding:16px 18px;border:1px solid var(--line);border-radius:10px;background:var(--panel)}pre code{padding:0;background:transparent}.syntax-keyword{color:var(--code-keyword);font-weight:600}.syntax-string{color:var(--code-string)}.syntax-comment{color:var(--code-comment);font-style:italic}.syntax-number{color:var(--code-number)}
            .table-scroll{overflow-x:auto;margin:1em 0}table{width:100%;border-collapse:collapse;font-size:.94em}th,td{padding:8px 11px;border:1px solid var(--line)}th{background:var(--panel);font-weight:600}img{display:block;max-width:100%;height:auto;margin:1.2em auto;border-radius:9px}.blocked-resource{display:inline-flex;padding:9px 12px;border:1px dashed var(--line);border-radius:8px;background:var(--panel);color:var(--muted);font-size:.88em}.math-display{display:block;overflow-x:auto;margin:1.2em 0;text-align:center}.footnotes{margin-top:2.4em;color:var(--muted);font-size:.88em}.footnote-ref{font-size:.72em}.footnote-backref{margin-left:.3em}
            </style>
            </head><body><main>\(body)</main>
            <script>\(katexJS)</script>
            <script>
            (()=>{'use strict';document.querySelectorAll('.math').forEach((node)=>{try{katex.render(node.dataset.tex||'',node,{displayMode:node.classList.contains('math-display'),throwOnError:false,strict:'warn',trust:false,output:'htmlAndMathml'});}catch(_){}});const blocks=()=>Array.from(document.querySelectorAll('.source-block[data-source-line]'));window.clipScrollToSourceLine=(line)=>{const all=blocks();let target=all[0];for(const block of all){if(Number(block.dataset.sourceLine)<=Number(line)){target=block;}else{break;}}if(target){window.scrollTo({top:Math.max(0,target.offsetTop-20),behavior:'auto'});}};let pending=false;window.addEventListener('scroll',()=>{if(pending)return;pending=true;requestAnimationFrame(()=>{pending=false;let nearest=null;let distance=Infinity;for(const block of blocks()){const value=Math.abs(block.getBoundingClientRect().top-20);if(value<distance){distance=value;nearest=block;}}const line=nearest?Number(nearest.dataset.sourceLine):1;window.webkit?.messageHandlers?.clipScrollSync?.postMessage(line);});},{passive:true});})();
            </script></body></html>
            """
    }
}

private enum MarkdownPreviewAssets {
    static let katexJavaScript = resource(named: "katex.min", extension: "js")
    static let katexCSS: String = {
        var css = resource(named: "katex.min", extension: "css")
        let directory = Bundle.module.bundleURL
            .appendingPathComponent("Resources/KaTeX/fonts", isDirectory: true)
        if let fonts = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for font in fonts where font.pathExtension == "woff2" {
                guard let data = try? Data(contentsOf: font) else { continue }
                css = css.replacingOccurrences(
                    of: "url(fonts/\(font.lastPathComponent))",
                    with: "url(data:font/woff2;base64,\(data.base64EncodedString()))"
                )
            }
        }
        return css
    }()

    private static func resource(named name: String, extension fileExtension: String) -> String {
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Resources/KaTeX"
            ), let value = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return value
    }
}

private func imageMIMEType(for pathExtension: String) -> String? {
    switch pathExtension.lowercased() {
    case "gif": "image/gif"
    case "heic": "image/heic"
    case "jpeg", "jpg": "image/jpeg"
    case "png": "image/png"
    case "tif", "tiff": "image/tiff"
    case "webp": "image/webp"
    default: nil
    }
}

private func identifier(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
}

private func htmlText(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func htmlAttribute(_ value: String) -> String {
    htmlText(value)
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
