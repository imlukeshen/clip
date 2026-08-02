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
            color: CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        ).cropped(to: bounds)
        var sources: [(ReelVideoLayer, CIImage)] = []
        for layer in instruction.layers {
            guard let sourceBuffer = request.sourceFrame(byTrackID: layer.sourceTrackID) else {
                continue
            }
            sources.append((layer, CIImage(cvPixelBuffer: sourceBuffer)))
        }
        let composed = VideoLayerRenderer.compose(
            sources,
            at: request.compositionTime.rational,
            bounds: bounds,
            background: background
        )

        context.render(
            composed, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }
}

/// Shared V2 layer renderer used by preview/export and directly testable with
/// deterministic Core Image fixtures.
enum VideoLayerRenderer {
    static func compose(
        _ sources: [(ReelVideoLayer, CIImage)],
        at projectTime: RationalTime,
        bounds: CGRect,
        background: CIImage
    ) -> CIImage {
        var composed = background
        for (index, source) in sources.enumerated() {
            let (layer, sourceImage) = source
            var image = sourceImage.transformed(by: layer.preferredTransform)
            image = image.transformed(
                by: CGAffineTransform(
                    translationX: -image.extent.minX,
                    y: -image.extent.minY
                )
            )

            let timelineLocal = projectTime - layer.item.timelineStart
            let sourceLocal = timelineLocal.scaled(
                by: layer.item.speed
            )
            let effectBackground: CIImage
            if index == 0, layer.item.transform == .identity {
                // This is deliberately the v1 path: identical source, effect,
                // and canvas-background inputs preserve migrated rendering.
                effectBackground = FrameEffectRenderer.background(
                    background: background,
                    effects: layer.item.effects,
                    at: sourceLocal,
                    bounds: bounds
                )
            } else {
                effectBackground = CIImage(color: .clear).cropped(to: bounds)
            }
            image = FrameEffectRenderer.render(
                image,
                effects: layer.item.effects,
                at: sourceLocal,
                bounds: bounds,
                background: effectBackground
            )
            image = transformed(
                image,
                by: layer.item.transform,
                in: bounds
            )
            let transitionOpacity = layer.item.videoFade.value(
                at: timelineLocal,
                duration: layer.item.timelineDuration
            )
            image = applyingOpacity(layer.item.opacity * transitionOpacity, to: image)
            composed = blend(image, over: composed, mode: layer.item.blendMode)
        }
        return composed.cropped(to: bounds)
    }

    private static func transformed(
        _ image: CIImage,
        by transform: Transform2D,
        in bounds: CGRect
    ) -> CIImage {
        guard transform != .identity else { return image }
        let radians = -transform.rotationDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let a = transform.scaleX * cosine
        let b = transform.scaleX * sine
        let c = -transform.scaleY * sine
        let d = transform.scaleY * cosine
        let destinationX = bounds.midX + transform.translationX * bounds.width
        let destinationY = bounds.midY - transform.translationY * bounds.height
        let affine = CGAffineTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: destinationX - a * bounds.midX - c * bounds.midY,
            ty: destinationY - b * bounds.midX - d * bounds.midY
        )
        return image.transformed(by: affine).cropped(to: bounds)
    }

    private static func applyingOpacity(_ opacity: Double, to image: CIImage) -> CIImage {
        guard opacity < 1 else { return image }
        return image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ]
        )
    }

    private static func blend(
        _ foreground: CIImage,
        over background: CIImage,
        mode: BlendMode
    ) -> CIImage {
        switch mode {
        case .normal:
            foreground.composited(over: background)
        case .multiply:
            foreground.applyingFilter(
                "CIMultiplyBlendMode",
                parameters: [kCIInputBackgroundImageKey: background]
            )
        case .screen:
            foreground.applyingFilter(
                "CIScreenBlendMode",
                parameters: [kCIInputBackgroundImageKey: background]
            )
        case .overlay:
            foreground.applyingFilter(
                "CIOverlayBlendMode",
                parameters: [kCIInputBackgroundImageKey: background]
            )
        }
    }
}
