import Foundation
import TextEngine

/// Phase-V edge shared by the LaTeX editor and conversion queue.
public struct TectonicBackend: ConversionBackend {
    public let id: BackendID = .tectonic
    private let engine: any TeXEngine

    public init(engine: any TeXEngine = TectonicEngine()) {
        self.engine = engine
    }

    public var isAvailable: Bool { engine.isAvailable }

    public func edges() -> [ConversionEdge] {
        guard isAvailable else { return [] }
        return [
            ConversionEdge(
                from: .exact(ConversionFormats.latex),
                to: ConversionFormats.pdf,
                backend: id,
                implementation: .tectonic,
                cost: .expensive,
                isLossless: false,
                warnings: ["TeX package downloads require consent in the editor"]
            )
        ]
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        guard step.from == ConversionFormats.latex, step.to == ConversionFormats.pdf else {
            return failedStream(ConversionError.invalidInput)
        }
        guard isAvailable else {
            return failedStream(
                ConversionError.backendUnavailable("The bundled Tectonic engine is unavailable")
            )
        }
        let engine = engine
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(0)
                    let stream = engine.compile(
                        TeXJob(
                            mainFile: input,
                            timeout: .seconds(120),
                            packageAccess: .cachedOnly
                        )
                    )
                    for try await event in stream {
                        switch event {
                        case .pass(let pass, let total):
                            continuation.yield(Double(pass) / Double(max(total + 1, 1)))
                        case .finished(let pdf, _):
                            defer {
                                try? FileManager.default.removeItem(
                                    at: pdf.deletingLastPathComponent())
                            }
                            let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            try FileManager.default.copyItem(at: pdf, to: temporary)
                            try AtomicOutput.commit(temporary, to: output)
                            continuation.yield(1)
                        case .logLine, .diagnostic:
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ConversionError.cancelled)
                } catch TeXEngineError.cancelled {
                    continuation.finish(throwing: ConversionError.cancelled)
                } catch {
                    continuation.finish(
                        throwing: ConversionError.conversionFailed(error.localizedDescription)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
