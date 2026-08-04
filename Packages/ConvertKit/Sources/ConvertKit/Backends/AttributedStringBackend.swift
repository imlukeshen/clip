import AppKit
import Foundation

/// Native import/export for rich-text document formats supported by AppKit.
public struct AttributedStringBackend: ConversionBackend {
    public init() {}

    public var id: BackendID { .attributedString }
    public var isAvailable: Bool { true }

    public func edges() -> [ConversionEdge] {
        let readable = FormatMatcher.oneOf(ConversionFormats.richTextInputs)
        return [
            edge(from: readable, to: ConversionFormats.html, lossless: true),
            edge(from: readable, to: ConversionFormats.rtf, lossless: true),
            edge(from: readable, to: ConversionFormats.plainText, lossless: false),
            edge(from: readable, to: ConversionFormats.markdown, lossless: false),
        ]
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(0)
                    let attributed = try Self.read(input)
                    let data = try Self.encode(attributed, as: step.to)
                    let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try data.write(to: temporary, options: .atomic)
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

    private func edge(
        from: FormatMatcher,
        to: FormatID,
        lossless: Bool
    ) -> ConversionEdge {
        ConversionEdge(
            from: from,
            to: to,
            backend: id,
            implementation: .attributedString,
            cost: .cheap,
            isLossless: lossless,
            warnings: lossless ? [] : ["Some document formatting may not be preserved."],
            supportedOptions: [.stripMetadata]
        )
    }

    private static func read(_ url: URL) throws -> NSAttributedString {
        if url.pathExtension.lowercased() == "txt" {
            let text = try String(contentsOf: url, encoding: .utf8)
            return NSAttributedString(string: text)
        }
        do {
            return try NSAttributedString(
                url: url,
                options: [:],
                documentAttributes: nil
            )
        } catch {
            throw ConversionError.invalidInput
        }
    }

    private static func encode(_ value: NSAttributedString, as format: FormatID) throws -> Data {
        if format.type == ConversionFormats.plainText.type {
            return Data(value.string.utf8)
        }
        if format.type == ConversionFormats.markdown.type {
            return Data(value.string.utf8)
        }
        let documentType: NSAttributedString.DocumentType
        if format.type == ConversionFormats.html.type {
            documentType = .html
        } else if format.type == ConversionFormats.rtf.type {
            documentType = .rtf
        } else {
            throw ConversionError.unsupported("Unsupported rich-text output format")
        }
        return try value.data(
            from: NSRange(location: 0, length: value.length),
            documentAttributes: [.documentType: documentType]
        )
    }
}
