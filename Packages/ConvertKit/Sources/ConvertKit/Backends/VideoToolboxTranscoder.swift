@preconcurrency import AVFoundation
import Foundation

public actor VideoToolboxTranscoder: VideoTranscoding, ConversionBackend {
    public init() {}

    nonisolated public var id: BackendID { .videoToolbox }
    nonisolated public var isAvailable: Bool { true }

    nonisolated public func edges() -> [ConversionEdge] {
        [
            (ConversionFormats.mp4H264, Backend.videoToolbox(.h264)),
            (ConversionFormats.mp4HEVC, Backend.videoToolbox(.hevc)),
            (ConversionFormats.movH264, Backend.videoToolbox(.h264)),
            (ConversionFormats.movProRes422, Backend.videoToolbox(.proRes422)),
        ].map { target, implementation in
            ConversionEdge(
                from: .oneOf(ConversionFormats.videoInputs),
                to: target,
                backend: id,
                implementation: implementation,
                cost: .hardware,
                isLossless: false,
                warnings: ["The video will be re-encoded."],
                supportedOptions: [
                    .quality, .resize, .frameRate, .audio, .trim, .mute, .stripMetadata,
                ]
            )
        }
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        guard case .videoToolbox(let codec) = step.implementation else {
            return failedStream(ConversionError.invalidInput)
        }
        return await transcode(
            input: input,
            output: output,
            codec: codec,
            options: step.options
        )
    }

    func transcode(
        input: URL,
        output: URL,
        codec: VideoCodec
    ) async -> AsyncThrowingStream<Double, Error> {
        await transcode(
            input: input,
            output: output,
            codec: codec,
            options: ConversionOptions()
        )
    }

    func transcode(
        input: URL,
        output: URL,
        codec: VideoCodec,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(0)
                    try await AVExport.run(
                        input: input,
                        output: output,
                        preset: preset(for: codec),
                        fileType: AVExport.fileType(for: output),
                        options: options
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
