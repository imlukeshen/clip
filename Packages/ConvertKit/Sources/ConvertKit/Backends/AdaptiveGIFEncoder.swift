@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Samples a video directly into an indexed GIF and progressively lowers its
/// sampling profile only when a preset's hard byte ceiling requires it.
enum AdaptiveGIFEncoder {
    struct Profile: Sendable, Equatable {
        var maximumWidth: Int
        var maximumHeight: Int
        var framesPerSecond: Double
    }

    static func convert(
        input: URL,
        output: URL,
        options: ConversionOptions
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let profiles = profiles(for: options.video)
                    let maximumBytes = options.video?.maximumFileSize
                    for (index, profile) in profiles.enumerated() {
                        try Task.checkCancellation()
                        let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        try await encode(
                            input: input,
                            output: temporary,
                            profile: profile,
                            progress: { value in
                                let attemptProgress =
                                    (Double(index) + min(max(value, 0), 1))
                                    / Double(profiles.count)
                                continuation.yield(attemptProgress)
                            }
                        )
                        let byteSize =
                            try temporary.resourceValues(forKeys: [.fileSizeKey])
                            .fileSize ?? .max
                        if let maximumBytes, byteSize > maximumBytes { continue }
                        try AtomicOutput.commit(temporary, to: output)
                        continuation.yield(1)
                        continuation.finish()
                        return
                    }
                    throw ConversionError.conversionFailed(
                        "The GIF could not be reduced below the requested size limit."
                    )
                } catch is CancellationError {
                    continuation.finish(throwing: ConversionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func profiles(for options: VideoConversionOptions?) -> [Profile] {
        let requested = profile(for: options)
        guard options?.maximumFileSize != nil else { return [requested] }
        let fallbacks = [
            Profile(maximumWidth: 640, maximumHeight: 360, framesPerSecond: 12),
            Profile(maximumWidth: 426, maximumHeight: 240, framesPerSecond: 10),
            Profile(maximumWidth: 284, maximumHeight: 160, framesPerSecond: 8),
            Profile(maximumWidth: 178, maximumHeight: 100, framesPerSecond: 6),
        ]
        return [requested]
            + fallbacks.filter {
                $0.maximumWidth < requested.maximumWidth
                    || $0.framesPerSecond < requested.framesPerSecond
            }
    }

    private static func profile(for options: VideoConversionOptions?) -> Profile {
        let dimensions: (Int, Int)
        switch options?.resolution ?? .p480 {
        case .source: dimensions = (1_920, 1_080)
        case .p2160: dimensions = (3_840, 2_160)
        case .p1080: dimensions = (1_920, 1_080)
        case .p720: dimensions = (1_280, 720)
        case .p480: dimensions = (854, 480)
        case .custom(let width, let height): dimensions = (max(width, 1), max(height, 1))
        }
        return Profile(
            maximumWidth: dimensions.0,
            maximumHeight: dimensions.1,
            framesPerSecond: max(options?.frameRate ?? 15, 1)
        )
    }

    private static func encode(
        input: URL,
        output: URL,
        profile: Profile,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.invalidInput
        }
        let duration = try await asset.load(.duration).seconds
        let preferredTransform = try await track.load(.preferredTransform)
        guard duration.isFinite, duration > 0 else { throw ConversionError.invalidInput }
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { throw ConversionError.invalidInput }
        reader.add(trackOutput)

        let estimatedCount = max(Int(ceil(duration * profile.framesPerSecond)), 1)
        guard
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL,
                UTType.gif.identifier as CFString,
                estimatedCount,
                nil
            )
        else { throw ConversionError.cannotCreateOutput }
        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )
        guard reader.startReading() else {
            throw ConversionError.conversionFailed(
                reader.error?.localizedDescription ?? "Video decode failed")
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        let frameInterval = 1 / profile.framesPerSecond
        var nextFrameTime = 0.0
        var encodedCount = 0
        while let sample = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.000_1 >= nextFrameTime else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var source = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: preferredTransform)
            source = source.transformed(
                by: CGAffineTransform(
                    translationX: -source.extent.minX,
                    y: -source.extent.minY
                )
            )
            let scale = min(
                Double(profile.maximumWidth) / source.extent.width,
                Double(profile.maximumHeight) / source.extent.height,
                1
            )
            let transformed = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let image = context.createCGImage(transformed, from: transformed.extent) else {
                throw ConversionError.conversionFailed("GIF frame rendering failed")
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: frameInterval
                    ]
                ] as CFDictionary
            )
            encodedCount += 1
            nextFrameTime += frameInterval
            progress(min(time / duration, 0.99))
        }
        guard reader.status == .completed else {
            throw ConversionError.conversionFailed(
                reader.error?.localizedDescription ?? "Video decode failed"
            )
        }
        guard encodedCount > 0, CGImageDestinationFinalize(destination) else {
            throw ConversionError.conversionFailed("GIF encoding failed")
        }
    }
}
