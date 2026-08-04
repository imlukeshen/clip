@preconcurrency import AVFoundation
import Foundation

public actor RemuxTranscoder: Remuxing, ConversionBackend {
    public init() {}

    nonisolated public var id: BackendID { .passthrough }
    nonisolated public var isAvailable: Bool { true }

    nonisolated public func edges() -> [ConversionEdge] {
        [
            ConversionEdge(
                from: .exact(ConversionFormats.movH264),
                to: ConversionFormats.mp4H264,
                backend: id,
                implementation: .remux,
                cost: .passthrough,
                isLossless: true
            ),
            ConversionEdge(
                from: .exact(ConversionFormats.mp4H264),
                to: ConversionFormats.movH264,
                backend: id,
                implementation: .remux,
                cost: .passthrough,
                isLossless: true
            ),
        ]
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        guard step.backend == id else {
            return failedStream(ConversionError.invalidInput)
        }
        return await remux(input: input, output: output)
    }

    func remux(input: URL, output: URL) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(0)
                    try await AVExport.run(
                        input: input,
                        output: output,
                        preset: AVAssetExportPresetPassthrough,
                        fileType: AVExport.fileType(for: output)
                    )
                    continuation.yield(1)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
