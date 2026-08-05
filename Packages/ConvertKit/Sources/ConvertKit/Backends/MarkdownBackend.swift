import Foundation
import TextEngine

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
                    let html = MarkdownHTMLRenderer.render(
                        markdown,
                        destination: .export(baseDirectory: input.deletingLastPathComponent())
                    ).html
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

}
