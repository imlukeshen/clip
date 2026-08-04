import Foundation

/// Deterministic, offline Markdown conversion for the common document subset.
public struct MarkdownBackend: ConversionBackend {
    public init() {}

    public var id: BackendID { .markdown }
    public var isAvailable: Bool { true }

    public func edges() -> [ConversionEdge] {
        [
            ConversionEdge(
                from: .exact(ConversionFormats.markdown),
                to: ConversionFormats.html,
                backend: id,
                implementation: .markdown,
                cost: .cheap,
                isLossless: true,
                supportedOptions: [.stripMetadata]
            )
        ]
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        guard step.to.type == ConversionFormats.html.type else {
            return failedStream(ConversionError.unsupported("Unsupported Markdown output format"))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(0)
                    let markdown = try String(contentsOf: input, encoding: .utf8)
                    let html = Self.render(markdown)
                    let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Data(html.utf8).write(to: temporary, options: .atomic)
                    try AtomicOutput.commit(temporary, to: output)
                    continuation.yield(1)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ConversionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func render(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var body: [String] = []
        var paragraph: [String] = []
        var inList = false
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            body.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }
        func closeList() {
            guard inList else { return }
            body.append("</ul>")
            inList = false
        }

        for rawLine in lines {
            let line = String(rawLine)
            if line.hasPrefix("```") {
                flushParagraph()
                closeList()
                if inCode {
                    body.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                    code.removeAll()
                }
                inCode.toggle()
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                closeList()
                continue
            }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flushParagraph()
                closeList()
                body.append(
                    "<h\(hashes)>\(inline(String(line.dropFirst(hashes + 1))))</h\(hashes)>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                if !inList {
                    body.append("<ul>")
                    inList = true
                }
                body.append("<li>\(inline(String(line.dropFirst(2))))</li>")
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        flushParagraph()
        closeList()
        if inCode {
            body.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
        }
        return """
            <!doctype html>
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
            <style>body{font:16px -apple-system;margin:48px;line-height:1.5;color:#111}pre{padding:16px;background:#f5f5f7;border-radius:10px;overflow:auto}code{font-family:ui-monospace,monospace}</style>
            </head><body>\(body.joined(separator: "\n"))</body></html>
            """
    }

    private static func inline(_ value: String) -> String {
        var result = escape(value)
        result = replacing(
            pattern: #"\*\*([^*]+)\*\*"#, in: result, template: "<strong>$1</strong>")
        result = replacing(pattern: #"`([^`]+)`"#, in: result, template: "<code>$1</code>")
        result = replacing(
            pattern: #"\[([^\]]+)\]\((https?://[^\s)]+)\)"#,
            in: result,
            template: #"<a href="$2">$1</a>"#
        )
        return result
    }

    private static func replacing(pattern: String, in value: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
