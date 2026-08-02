@preconcurrency import AVFoundation
import Foundation

public actor RemuxTranscoder: Remuxing {
    public init() {}

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
