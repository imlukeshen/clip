import Foundation
import ReelFFmpeg

/// In-process FFmpeg entry point backed by the bundled LGPL framework.
public actor FFmpegTranscoder: FFmpegTranscoding, ConversionBackend {
    public init() {}

    nonisolated public var id: BackendID { .ffmpeg }
    nonisolated public var isAvailable: Bool { true }

    nonisolated public func edges() -> [ConversionEdge] {
        [
            ConversionEdge(
                from: .oneOf(ConversionFormats.videoInputs),
                to: ConversionFormats.webMVP9,
                backend: id,
                implementation: .ffmpeg(.webMVP9),
                cost: .expensive,
                isLossless: false,
                warnings: ["This format requires re-encoding."],
                supportedOptions: [
                    .quality, .resize, .frameRate, .audio, .trim, .stripMetadata,
                ]
            ),
            ConversionEdge(
                from: .oneOf(ConversionFormats.videoInputs),
                to: ConversionFormats.webMAV1,
                backend: id,
                implementation: .ffmpeg(.webMAV1),
                cost: .expensive,
                isLossless: false,
                warnings: ["This format requires re-encoding."],
                supportedOptions: [
                    .quality, .resize, .frameRate, .audio, .trim, .stripMetadata,
                ]
            ),
            ConversionEdge(
                from: .oneOf(ConversionFormats.videoInputs + ConversionFormats.imageInputs),
                to: ConversionFormats.animatedGIF,
                backend: id,
                implementation: .ffmpeg(.animatedGIF),
                cost: .expensive,
                isLossless: false,
                warnings: ["This format requires re-encoding."],
                supportedOptions: [
                    .quality, .resize, .frameRate, .trim, .stripMetadata,
                ]
            ),
            ConversionEdge(
                from: .oneOf(ConversionFormats.videoInputs),
                to: ConversionFormats.matroska,
                backend: id,
                implementation: .ffmpeg(.matroska),
                cost: .expensive,
                isLossless: false,
                warnings: ["This format requires re-encoding."],
                supportedOptions: [
                    .quality, .resize, .frameRate, .audio, .trim, .stripMetadata,
                ]
            ),
            ConversionEdge(
                from: .oneOf(ConversionFormats.audioInputs),
                to: ConversionFormats.flac,
                backend: id,
                implementation: .ffmpeg(.flac),
                cost: .expensive,
                isLossless: true,
                supportedOptions: [.audio, .trim, .stripMetadata]
            ),
            ConversionEdge(
                from: .oneOf([ConversionFormats.png, ConversionFormats.jpeg]),
                to: ConversionFormats.webP,
                backend: id,
                implementation: .ffmpeg(.webP),
                cost: .expensive,
                isLossless: false,
                warnings: ["This image format uses lossy compression."],
                supportedOptions: [.quality, .resize, .stripMetadata]
            ),
        ]
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        guard case .ffmpeg(let recipe) = step.implementation else {
            return failedStream(ConversionError.invalidInput)
        }
        return await transcode(input: input, output: output, recipe: recipe)
    }

    public func transcode(
        input: URL,
        output: URL,
        recipe: FFmpegRecipe
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let progress = FFmpegProgress(continuation: continuation)
            let task = Task.detached(priority: .userInitiated) {
                let temporary: URL
                do {
                    temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                defer { try? FileManager.default.removeItem(at: temporary) }

                var errorBuffer = [CChar](repeating: 0, count: 1_024)
                let result = input.path.withCString { inputPath in
                    temporary.path.withCString { outputPath in
                        reel_ffmpeg_transcode(
                            inputPath,
                            outputPath,
                            recipe.bridgeValue,
                            ffmpegProgressCallback,
                            Unmanaged.passUnretained(progress).toOpaque(),
                            &errorBuffer,
                            errorBuffer.count
                        )
                    }
                }

                if result == 0 {
                    do {
                        try AtomicOutput.commit(temporary, to: output)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } else if progress.isCancelled {
                    continuation.finish(throwing: ConversionError.cancelled)
                } else {
                    let message =
                        errorBuffer.withUnsafeBufferPointer { buffer in
                            buffer.baseAddress.map(String.init(cString:))
                        } ?? "FFmpeg conversion failed"
                    continuation.finish(
                        throwing: ConversionError.conversionFailed(message)
                    )
                }
            }
            continuation.onTermination = { _ in
                progress.cancel()
                task.cancel()
            }
        }
    }
}

extension FFmpegRecipe {
    fileprivate var bridgeValue: ReelFFmpegRecipe {
        switch self {
        case .webMVP9: ReelFFmpegRecipeWebMVP9
        case .webMAV1: ReelFFmpegRecipeWebMAV1
        case .animatedGIF: ReelFFmpegRecipeAnimatedGIF
        case .matroska: ReelFFmpegRecipeMatroska
        case .flac: ReelFFmpegRecipeFLAC
        case .webP: ReelFFmpegRecipeWebP
        }
    }
}

private let ffmpegProgressCallback:
    @convention(c) (
        Double,
        UnsafeMutableRawPointer?
    ) -> Int32 = { value, context in
        guard let context else { return 0 }
        return Unmanaged<FFmpegProgress>.fromOpaque(context).takeUnretainedValue()
            .report(value)
    }

private final class FFmpegProgress: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Double, Error>.Continuation
    private let lock = NSLock()
    private var cancelled = false

    init(continuation: AsyncThrowingStream<Double, Error>.Continuation) {
        self.continuation = continuation
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func report(_ value: Double) -> Int32 {
        lock.withLock {
            guard !cancelled else { return 0 }
            continuation.yield(min(max(value, 0), 1))
            return 1
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
