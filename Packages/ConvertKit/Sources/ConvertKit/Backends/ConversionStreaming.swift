import Foundation

public protocol FFmpegTranscoding: Sendable {
    func transcode(
        input: URL,
        output: URL,
        recipe: FFmpegRecipe
    ) async -> AsyncThrowingStream<Double, Error>
    func transcode(
        input: URL,
        output: URL,
        recipe: FFmpegRecipe,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error>
}

extension FFmpegTranscoding {
    public func transcode(
        input: URL,
        output: URL,
        recipe: FFmpegRecipe,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error> {
        await transcode(input: input, output: output, recipe: recipe)
    }
}

protocol Remuxing: Sendable {
    func remux(input: URL, output: URL) async -> AsyncThrowingStream<Double, Error>
    func remux(
        input: URL,
        output: URL,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error>
}

extension Remuxing {
    func remux(
        input: URL,
        output: URL,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error> {
        await remux(input: input, output: output)
    }
}

protocol VideoTranscoding: Sendable {
    func transcode(
        input: URL,
        output: URL,
        codec: VideoCodec
    ) async -> AsyncThrowingStream<Double, Error>
    func transcode(
        input: URL,
        output: URL,
        codec: VideoCodec,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error>
}

extension VideoTranscoding {
    func transcode(
        input: URL,
        output: URL,
        codec: VideoCodec,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error> {
        await transcode(input: input, output: output, codec: codec)
    }
}

protocol ImageTranscoding: Sendable {
    func transcode(
        input: URL,
        output: URL,
        format: ImageFormat
    ) async -> AsyncThrowingStream<Double, Error>
    func transcode(
        input: URL,
        output: URL,
        format: ImageFormat,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error>
}

extension ImageTranscoding {
    func transcode(
        input: URL,
        output: URL,
        format: ImageFormat,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error> {
        await transcode(input: input, output: output, format: format)
    }
}

func failedStream(_ error: Error) -> AsyncThrowingStream<Double, Error> {
    AsyncThrowingStream { continuation in continuation.finish(throwing: error) }
}
