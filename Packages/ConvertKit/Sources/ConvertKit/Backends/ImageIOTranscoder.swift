import Foundation
import ImageIO
import UniformTypeIdentifiers

public actor ImageIOTranscoder: ImageTranscoding {
    public init() {}

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
