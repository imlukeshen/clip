@preconcurrency import AVFoundation
import Foundation

public actor VideoToolboxTranscoder: VideoTranscoding {
    public init() {}

    func transcode(
        input: URL,
        output: URL,
        codec: VideoCodec
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(0)
                    try await AVExport.run(
                        input: input,
                        output: output,
                        preset: preset(for: codec),
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

    private func preset(for codec: VideoCodec) -> String {
        switch codec {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        }
    }
}
