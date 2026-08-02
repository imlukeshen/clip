import CoreImage
import CoreModel
import Foundation

enum FrameEffectRenderer {
    static func background(
        _ canvasColor: RGBA,
        effects: [Effect],
        at time: RationalTime,
        bounds: CGRect
    ) -> CIImage {
        let effect = effects.compactMap { effect -> BackgroundEffect? in
            guard case .background(let value) = effect, value.range.contains(time) else {
                return nil
            }
            return value
        }.last
        let color: RGBA
        if let effect, case .solid(let value) = effect.style {
            color = value
        } else {
            color = canvasColor
        }
        return CIImage(color: color.ciColor).cropped(to: bounds)
    }

    static func render(
        _ source: CIImage,
        effects: [Effect],
        at time: RationalTime,
        bounds: CGRect,
        background: CIImage
    ) -> CIImage {
        var image = crop(source, effects: effects, at: time)
        guard image.extent.width > 0, image.extent.height > 0 else { return background }

        let presentation = effects.compactMap { effect -> BackgroundEffect? in
            guard case .background(let value) = effect, value.range.contains(time) else {
                return nil
            }
            return value
        }.last
        let inset = min(
            max(CGFloat(presentation?.padding ?? 0) * bounds.width, 0),
            min(bounds.width, bounds.height) / 2 - 1
        )
        let target = bounds.insetBy(dx: inset, dy: inset)
        image = aspectFit(image, in: target)
        if let presentation {
            image = framed(image, effect: presentation, background: background)
        }

        let zooms = effects.compactMap { effect -> ZoomEffect? in
            if case .zoom(let value) = effect { return value }
            return nil
        }
        let zoom = ZoomEvaluator.state(at: time, effects: zooms)
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

        image = blur(image.cropped(to: bounds), effects: effects, at: time, bounds: bounds)
        return image.cropped(to: bounds).composited(over: background)
    }

    private static func crop(
        _ image: CIImage,
        effects: [Effect],
        at time: RationalTime
    ) -> CIImage {
        guard
            let effect = effects.compactMap({ effect -> CropEffect? in
                guard case .crop(let value) = effect, value.range.contains(time) else {
                    return nil
                }
                return value
            }).last
        else { return image }
        let normalized = effect.rect.clamped
        let extent = image.extent
        let cropRect = CGRect(
            x: extent.minX + CGFloat(normalized.x) * extent.width,
            y: extent.minY + CGFloat(1 - normalized.y - normalized.height) * extent.height,
            width: CGFloat(normalized.width) * extent.width,
            height: CGFloat(normalized.height) * extent.height
        ).intersection(extent)
        guard !cropRect.isEmpty else { return image }
        let cropped = image.cropped(to: cropRect)
        return cropped.transformed(
            by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        )
    }

    private static func aspectFit(_ image: CIImage, in target: CGRect) -> CIImage {
        let factor = min(target.width / image.extent.width, target.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return scaled.transformed(
            by: CGAffineTransform(
                translationX: target.midX - scaled.extent.midX,
                y: target.midY - scaled.extent.midY
            )
        )
    }

    private static func framed(
        _ image: CIImage,
        effect: BackgroundEffect,
        background: CIImage
    ) -> CIImage {
        let extent = image.extent
        guard effect.cornerRadius > 0 || effect.shadow != nil else { return image }
        let mask = roundedMask(extent: extent, radius: max(effect.cornerRadius, 0))
        let transparent = CIImage(color: .clear).cropped(to: background.extent)
        let clipped = image.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: mask,
            ]
        )
        guard let shadow = effect.shadow else { return clipped }
        let shadowMask =
            mask
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: max(shadow.radius, 0)]
            )
            .cropped(to: background.extent)
            .transformed(
                by: CGAffineTransform(
                    translationX: shadow.offsetX,
                    y: -shadow.offsetY
                )
            )
        let shadowImage = CIImage(color: shadow.color.ciColor)
            .cropped(to: background.extent)
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: transparent,
                    kCIInputMaskImageKey: shadowMask,
                ]
            )
        return clipped.composited(over: shadowImage)
    }

    private static func roundedMask(extent: CGRect, radius: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: .white).cropped(to: extent)
        }
        filter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: "inputColor")
        return filter.outputImage?.cropped(to: extent)
            ?? CIImage(color: .white).cropped(to: extent)
    }

    private static func blur(
        _ image: CIImage,
        effects: [Effect],
        at time: RationalTime,
        bounds: CGRect
    ) -> CIImage {
        var result = image
        for effect in effects {
            guard case .blur(let value) = effect, value.range.contains(time),
                let region = value.region(at: time)
            else { continue }
            let blurred: CIImage
            switch value.mode {
            case .gaussian(let radius):
                blurred = result.clampedToExtent().applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: max(radius, 0)]
                ).cropped(to: bounds)
            case .pixelate(let size):
                blurred = result.applyingFilter(
                    "CIPixellate",
                    parameters: [
                        kCIInputScaleKey: max(size, 1),
                        kCIInputCenterKey: CIVector(x: bounds.midX, y: bounds.midY),
                    ]
                ).cropped(to: bounds)
            }
            let mask = region.mask(in: bounds)
            result = blurred.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: result,
                    kCIInputMaskImageKey: mask,
                ]
            )
        }
        return result
    }
}

extension TimeRange {
    fileprivate func contains(_ time: RationalTime) -> Bool {
        time >= start && time < end
    }
}

extension NormalizedRect {
    fileprivate var clamped: NormalizedRect {
        let x = min(max(self.x, 0), 1)
        let y = min(max(self.y, 0), 1)
        return NormalizedRect(
            x: x,
            y: y,
            width: min(max(width, 0), 1 - x),
            height: min(max(height, 0), 1 - y)
        )
    }

    fileprivate func mask(in bounds: CGRect) -> CIImage {
        let value = clamped
        let region = CGRect(
            x: bounds.minX + CGFloat(value.x) * bounds.width,
            y: bounds.minY + CGFloat(1 - value.y - value.height) * bounds.height,
            width: CGFloat(value.width) * bounds.width,
            height: CGFloat(value.height) * bounds.height
        )
        let black = CIImage(color: .black).cropped(to: bounds)
        return CIImage(color: .white).cropped(to: region).composited(over: black)
    }
}

extension BlurEffect {
    fileprivate func region(at time: RationalTime) -> NormalizedRect? {
        regions.last(where: { $0.time <= time })?.rect ?? regions.first?.rect
    }
}

extension RGBA {
    fileprivate var ciColor: CIColor {
        CIColor(red: r, green: g, blue: b, alpha: a)
    }
}
