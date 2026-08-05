@preconcurrency import AVFoundation
import CoreImage
import CoreModel
import Foundation

/// Turns a still image into a short, timeline-compatible movie without invoking
/// an external converter. It emits a conventional 30 fps hold so AVFoundation
/// preserves the requested duration consistently across codec implementations.
public struct StillImageClipBuilder: Sendable {
    public static let defaultDuration = RationalTime(seconds: 3)

    public init() {}

    public func build(
        imageAt imageURL: URL,
        outputURL: URL,
        duration: RationalTime = Self.defaultDuration
    ) async throws {
        guard duration > .zero,
            let source = CIImage(
                contentsOf: imageURL,
                options: [.applyOrientationProperty: true]
            )
        else {
            throw MediaEngineError.exportFailed("The pasted image could not be decoded.")
        }

        let extent = source.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
            extent.width > 0, extent.height > 0
        else {
            throw MediaEngineError.exportFailed("The pasted image has invalid dimensions.")
        }
        let size = outputSize(for: extent.size)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw MediaEngineError.exportFailed("The still-image clip could not be created.")
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_000_000
                ],
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaEngineError.exportFailed("The still-image video track is unavailable.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaEngineError.exportFailed(
                writer.error?.localizedDescription ?? "The still-image clip could not start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw MediaEngineError.exportFailed("The still-image frame buffer is unavailable.")
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer
        else {
            writer.cancelWriting()
            throw MediaEngineError.exportFailed("The still-image frame could not be allocated.")
        }

        let bounds = CGRect(origin: .zero, size: size)
        let frame = fittedImage(source, sourceExtent: extent, bounds: bounds)
        CIContext().render(
            frame,
            to: pixelBuffer,
            bounds: bounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        let frameRate: Int32 = 30
        let frameCount = max(1, Int((duration.seconds * Double(frameRate)).rounded()))
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            let presentationTime = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: frameRate
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                writer.cancelWriting()
                throw MediaEngineError.exportFailed(
                    writer.error?.localizedDescription
                        ?? "The still-image frame could not be written."
                )
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw MediaEngineError.exportFailed(
                writer.error?.localizedDescription ?? "The still-image clip could not be finished."
            )
        }
    }

    private func outputSize(for input: CGSize) -> CGSize {
        let maximumDimension: CGFloat = 1_920
        let scale = min(1, maximumDimension / max(input.width, input.height))
        return CGSize(
            width: evenDimension(input.width * scale),
            height: evenDimension(input.height * scale)
        )
    }

    private func evenDimension(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int(value.rounded(.down)) / 2 * 2))
    }

    private func fittedImage(
        _ source: CIImage,
        sourceExtent: CGRect,
        bounds: CGRect
    ) -> CIImage {
        let normalized = source.transformed(
            by: CGAffineTransform(
                translationX: -sourceExtent.minX,
                y: -sourceExtent.minY
            )
        )
        let scale = min(
            bounds.width / sourceExtent.width,
            bounds.height / sourceExtent.height
        )
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(
            by: CGAffineTransform(
                translationX: (bounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (bounds.height - scaled.extent.height) / 2 - scaled.extent.minY
            )
        )
        let background = CIImage(color: .black).cropped(to: bounds)
        return centered.composited(over: background).cropped(to: bounds)
    }
}
