import CoreGraphics
import CoreImage
import CoreModel
import CoreText
import Foundation

/// Draws the caption active at a moment as subtitle text near the bottom of
/// the frame: white text on a translucent dark box, sized to the frame, so it
/// reads on any footage and matches between preview and export.
enum CaptionOverlay {
    /// The caption on screen at `time`; when segments overlap the later one wins.
    static func active(_ captions: [CaptionSegment], at time: RationalTime) -> CaptionSegment? {
        captions.last { time >= $0.range.start && time < $0.range.end }
    }

    /// The caption as an image positioned within `bounds` (Core Image space),
    /// or `nil` for blank text.
    static func image(for text: String, in bounds: CGRect) -> CIImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }

        let fontSize = max(bounds.height * 0.045, 12)
        let padding = (horizontal: fontSize * 0.6, vertical: fontSize * 0.3)
        let font =
            CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let paragraph = centeredParagraphStyle()
        let attributed = NSAttributedString(
            string: trimmed,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maximumTextWidth = bounds.width * 0.8 - padding.horizontal * 2
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maximumTextWidth, height: bounds.height * 0.4),
            nil
        )
        let box = CGSize(
            width: ceil(textSize.width + padding.horizontal * 2),
            height: ceil(textSize.height + padding.vertical * 2)
        )
        guard
            let context = CGContext(
                data: nil,
                width: Int(box.width),
                height: Int(box.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        let radius = fontSize * 0.3
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.62))
        context.addPath(
            CGPath(
                roundedRect: CGRect(origin: .zero, size: box),
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
        context.fillPath()
        let textRect = CGRect(
            x: padding.horizontal,
            y: padding.vertical,
            width: box.width - padding.horizontal * 2,
            height: box.height - padding.vertical * 2
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: textRect, transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
        guard let cgImage = context.makeImage() else { return nil }
        let origin = CGPoint(
            x: bounds.minX + (bounds.width - box.width) / 2,
            y: bounds.minY + bounds.height * 0.06
        )
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    private static func centeredParagraphStyle() -> CTParagraphStyle {
        var alignment = CTTextAlignment.center
        return withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
    }
}
