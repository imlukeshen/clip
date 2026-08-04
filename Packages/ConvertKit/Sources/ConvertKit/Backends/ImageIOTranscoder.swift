import Foundation
import ImageIO
import UniformTypeIdentifiers

public actor ImageIOTranscoder: ImageTranscoding, ConversionBackend {
    public init() {}

    nonisolated public var id: BackendID { .imageIO }
    nonisolated public var isAvailable: Bool { true }

    nonisolated public func edges() -> [ConversionEdge] {
        [
            (ConversionFormats.png, Backend.imageIO(.png), true),
            (ConversionFormats.jpeg, Backend.imageIO(.jpeg), false),
            (ConversionFormats.heic, Backend.imageIO(.heic), false),
            (ConversionFormats.tiff, Backend.imageIO(.tiff), true),
        ].map { target, implementation, lossless in
            ConversionEdge(
                from: .oneOf(ConversionFormats.imageInputs + ConversionFormats.rawInputs),
                to: target,
                backend: id,
                implementation: implementation,
                cost: .cheap,
                isLossless: lossless,
                warnings: lossless ? [] : ["This image format uses lossy compression."],
                supportedOptions: [.quality, .resize, .stripMetadata]
            )
        }
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        guard case .imageIO(let format) = step.implementation else {
            return failedStream(ConversionError.invalidInput)
        }
        return await transcode(input: input, output: output, format: format)
    }

    func transcode(
        input: URL,
        output: URL,
        format: ImageFormat
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            do {
                continuation.yield(0)
                let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                    let destination = CGImageDestinationCreateWithURL(
                        temporary as CFURL,
                        contentType(for: format).identifier as CFString,
                        1,
                        nil
                    )
                else {
                    throw ConversionError.invalidInput
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                CGImageDestinationAddImage(destination, image, properties)
                guard CGImageDestinationFinalize(destination) else {
                    throw ConversionError.conversionFailed("ImageIO export failed")
                }
                try AtomicOutput.commit(temporary, to: output)
                continuation.yield(1)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func contentType(for format: ImageFormat) -> UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        }
    }
}
