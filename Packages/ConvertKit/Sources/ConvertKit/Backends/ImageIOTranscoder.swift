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
        return await transcode(
            input: input,
            output: output,
            format: format,
            options: step.options
        )
    }

    func transcode(
        input: URL,
        output: URL,
        format: ImageFormat
    ) async -> AsyncThrowingStream<Double, Error> {
        await transcode(
            input: input,
            output: output,
            format: format,
            options: ConversionOptions()
        )
    }

    func transcode(
        input: URL,
        output: URL,
        format: ImageFormat,
        options: ConversionOptions
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            do {
                continuation.yield(0)
                let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                    let originalImage = CGImageSourceCreateImageAtIndex(
                        source, 0,
                        [
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary)
                else {
                    throw ConversionError.invalidInput
                }
                let sourceImage: CGImage
                if options.removesMetadata {
                    sourceImage =
                        CGImageSourceCreateThumbnailAtIndex(
                            source,
                            0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: max(
                                    originalImage.width,
                                    originalImage.height
                                ),
                            ] as CFDictionary
                        ) ?? originalImage
                } else {
                    sourceImage = originalImage
                }
                let image = try Self.render(sourceImage, format: format, options: options.image)
                var properties: [CFString: Any] = [:]
                if !options.removesMetadata,
                    let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                        as? [CFString: Any]
                {
                    properties = sourceProperties
                }
                try Self.encode(
                    image,
                    format: format,
                    properties: properties,
                    requestedQuality: options.image?.quality,
                    maximumFileSize: options.image?.maximumFileSize,
                    to: temporary
                )
                try AtomicOutput.commit(temporary, to: output)
                continuation.yield(1)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private static func encode(
        _ sourceImage: CGImage,
        format: ImageFormat,
        properties sourceProperties: [CFString: Any],
        requestedQuality: Double?,
        maximumFileSize: Int?,
        to temporary: URL
    ) throws {
        if let maximumFileSize, maximumFileSize <= 0 {
            throw ConversionError.conversionFailed("The maximum image file size must be positive")
        }
        let isLossy = format == .jpeg || format == .heic
        var quality = min(max(requestedQuality ?? 0.82, 0.06), 1)
        var scale = 1.0
        var lastSize = 0
        var lastDimensions = (sourceImage.width, sourceImage.height)

        for _ in 0..<16 {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: temporary)
            let image: CGImage
            if scale < 0.999 {
                image = try render(
                    sourceImage,
                    format: format,
                    options: ImageConversionOptions(resize: .percentage(scale * 100))
                )
            } else {
                image = sourceImage
            }
            lastDimensions = (image.width, image.height)
            guard
                let destination = CGImageDestinationCreateWithURL(
                    temporary as CFURL,
                    contentType(for: format).identifier as CFString,
                    1,
                    nil
                )
            else { throw ConversionError.cannotCreateOutput }
            var properties = sourceProperties
            if isLossy {
                properties[kCGImageDestinationLossyCompressionQuality] = quality
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConversionError.conversionFailed("ImageIO export failed")
            }
            guard let maximumFileSize else { return }
            let size =
                try
                (FileManager.default.attributesOfItem(atPath: temporary.path)[.size]
                as? NSNumber)?.intValue ?? .max
            lastSize = size
            if size <= maximumFileSize { return }

            let ratio = sqrt(Double(maximumFileSize) / Double(max(size, 1))) * 0.92
            if isLossy, quality > 0.121 {
                quality = max(0.12, quality * min(max(ratio, 0.45), 0.8))
            } else {
                scale *= min(max(ratio, 0.18), 0.82)
            }
        }
        throw ConversionError.conversionFailed(
            "The image could not be reduced below \(maximumFileSize ?? 0) bytes "
                + "(last attempt: \(lastSize) bytes at \(lastDimensions.0)x\(lastDimensions.1))"
        )
    }

    private static func render(
        _ image: CGImage,
        format: ImageFormat,
        options: ImageConversionOptions?
    ) throws -> CGImage {
        let size = outputSize(for: image, resize: options?.resize)
        let needsFlattening = format == .jpeg || options?.backgroundColor != nil
        let requestedColorSpace: CGColorSpace?
        switch options?.colorProfile ?? .preserve {
        case .preserve: requestedColorSpace = image.colorSpace
        case .sRGB: requestedColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: requestedColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        }
        guard
            size.width != image.width || size.height != image.height || needsFlattening
                || options?.colorProfile != .preserve
        else { return image }
        guard
            let context = CGContext(
                data: nil,
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: requestedColorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw ConversionError.cannotCreateOutput }
        let background = options?.backgroundColor ?? .white
        if needsFlattening {
            context.setFillColor(
                red: background.red,
                green: background.green,
                blue: background.blue,
                alpha: background.alpha
            )
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let result = context.makeImage() else {
            throw ConversionError.conversionFailed("Image resize failed")
        }
        return result
    }

    private static func outputSize(for image: CGImage, resize: ImageResize?) -> (
        width: Int, height: Int
    ) {
        guard let resize else { return (image.width, image.height) }
        switch resize {
        case .longestSide(let length):
            let scale = min(Double(max(length, 1)) / Double(max(image.width, image.height)), 1)
            return (
                max(Int((Double(image.width) * scale).rounded()), 1),
                max(Int((Double(image.height) * scale).rounded()), 1)
            )
        case .exact(let width, let height):
            return (max(width, 1), max(height, 1))
        case .percentage(let percentage):
            let scale = max(percentage, 0.01) / 100
            return (
                max(Int((Double(image.width) * scale).rounded()), 1),
                max(Int((Double(image.height) * scale).rounded()), 1)
            )
        }
    }

    private nonisolated static func contentType(for format: ImageFormat) -> UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        }
    }
}
