@preconcurrency import AVFoundation
import CoreImage
import CoreModel
import Foundation
import Metal
import os

public final class EffectCompositor: NSObject, AVVideoCompositing, Sendable {
    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ]

    private let renderQueue = DispatchQueue(label: "app.reel.media-compositor")
    private let context: CIContext
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    let contextCreationCount = 1

    public override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device)
        } else {
            context = CIContext(options: [.cacheIntermediates: true])
        }
        super.init()
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        cancelled.withLock { $0 = false }
    }

    public func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest)
    {
        let context = context
        let cancelled = cancelled
        renderQueue.async {
            if cancelled.withLock({ $0 }) {
                asyncVideoCompositionRequest.finishCancelledRequest()
                return
            }
            Self.render(asyncVideoCompositionRequest, using: context)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        cancelled.withLock { $0 = true }
    }

    private static func render(
        _ request: AVAsynchronousVideoCompositionRequest,
        using context: CIContext
    ) {
        guard let instruction = request.videoCompositionInstruction as? ReelVideoInstruction,
            let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: MediaEngineError.cannotCreateTrack)
            return
        }
        let bounds = CGRect(origin: .zero, size: request.renderContext.size)
        let color = instruction.background
        let background = CIImage(
            color: CIColor(
                red: color.r,
                green: color.g,
                blue: color.b,
                alpha: color.a
            )
        ).cropped(to: bounds)

        var composed = background
        if let trackID = instruction.sourceTrackID,
            let sourceBuffer = request.sourceFrame(byTrackID: trackID)
        {
            var image = CIImage(cvPixelBuffer: sourceBuffer)
                .transformed(by: instruction.preferredTransform)
            image = image.transformed(
                by: CGAffineTransform(
                    translationX: -image.extent.minX,
                    y: -image.extent.minY
                )
            )
            if image.extent.width > 0, image.extent.height > 0 {
                let fit = min(
                    bounds.width / image.extent.width,
                    bounds.height / image.extent.height
                )
                image = image.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
                image = image.transformed(
                    by: CGAffineTransform(
                        translationX: (bounds.width - image.extent.width) / 2,
                        y: (bounds.height - image.extent.height) / 2
                    )
                )
            }

            let timelineLocal = (request.compositionTime - instruction.timeRange.start).rational
            let sourceLocal = timelineLocal.scaled(by: instruction.speed)
            let zooms = instruction.effects.compactMap { effect -> ZoomEffect? in
                if case .zoom(let zoom) = effect { return zoom }
                return nil
            }
            let zoom = ZoomEvaluator.state(at: sourceLocal, effects: zooms)
            if zoom.scale != 1 {
                image = image.transformed(
                    by: CGAffineTransform(
                        a: zoom.scale,
                        b: 0,
                        c: 0,
                        d: zoom.scale,
                        tx: bounds.midX - zoom.center.x * bounds.width * zoom.scale,
                        ty: bounds.midY - zoom.center.y * bounds.height * zoom.scale
                    )
                )
            }
            composed = image.cropped(to: bounds).composited(over: background)
        }

        context.render(
            composed, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }
}
