import Foundation

public protocol FFmpegTranscoding: Sendable {
    func transcode(
        input: URL,
        output: URL,
        recipe: FFmpegRecipe
    ) async -> AsyncThrowingStream<Double, Error>
}

protocol Remuxing: Sendable {
    func remux(input: URL, output: URL) async -> AsyncThrowingStream<Double, Error>
}

protocol VideoTranscoding: Sendable {
    func transcode(
        input: URL,
        output: URL,
        codec: VideoCodec
    ) async -> AsyncThrowingStream<Double, Error>
}

protocol ImageTranscoding: Sendable {
    func transcode(
        input: URL,
        output: URL,
        format: ImageFormat
    ) async -> AsyncThrowingStream<Double, Error>
}

func failedStream(_ error: Error) -> AsyncThrowingStream<Double, Error> {
    AsyncThrowingStream { continuation in continuation.finish(throwing: error) }
}
