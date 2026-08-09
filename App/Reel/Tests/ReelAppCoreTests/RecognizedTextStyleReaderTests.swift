import AppKit
import CoreGraphics
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

/// Renders text whose properties are known, then checks the reader recovers
/// them from the pixels alone. There is no API that names the font in a
/// rasterised image, so recovering size, weight, and the two colours is what a
/// convincing replacement actually depends on.
@Suite("Recognized text style reader")
@MainActor
struct RecognizedTextStyleReaderTests {
    @Test("Dark text on a light page reports both colours the right way round")
    func readsDarkOnLight() throws {
        let page = try render(
            "Booking number",
            fontSize: 40,
            weight: .regular,
            foreground: .black,
            background: .white
        )
        let style = try #require(
            RecognizedTextStyleReader.style(in: page.image, region: page.region, text: page.text))

        #expect(style.foreground.r < 0.3)
        #expect(style.background.r > 0.7)
    }

    @Test("Light text on a dark page is not read inside out")
    func readsLightOnDark() throws {
        let page = try render(
            "Booking number",
            fontSize: 40,
            weight: .regular,
            foreground: .white,
            background: .black
        )
        let style = try #require(
            RecognizedTextStyleReader.style(in: page.image, region: page.region, text: page.text))

        // Heavy or large text can cover more of its box than the page does, so
        // the reader must decide from the border rather than from area.
        #expect(style.foreground.r > 0.7)
        #expect(style.background.r < 0.3)
    }

    @Test("Measured point size tracks the size the text was drawn at")
    func recoversFontSize() throws {
        for fontSize in [24.0, 40.0, 64.0] {
            let page = try render(
                "Hamburgefons",
                fontSize: fontSize,
                weight: .regular,
                foreground: .black,
                background: .white
            )
            let style = try #require(
                RecognizedTextStyleReader.style(
                    in: page.image, region: page.region, text: page.text)
            )
            // Cap height varies a little by glyph set, so allow a quarter.
            #expect(abs(style.fontSize - fontSize) / fontSize < 0.25)
        }
    }

    @Test("Heavier text reads as a heavier weight")
    func heavierTextReadsHeavier() throws {
        func stemWeight(_ weight: NSFont.Weight) throws -> RecognizedTextStyle.Weight {
            let page = try render(
                "Hamburgefons",
                fontSize: 48,
                weight: weight,
                foreground: .black,
                background: .white
            )
            return try #require(
                RecognizedTextStyleReader.style(
                    in: page.image, region: page.region, text: page.text)
            ).weight
        }

        let regular = try stemWeight(.regular)
        let bold = try stemWeight(.bold)
        let ordering = RecognizedTextStyle.Weight.allCases
        let regularIndex = try #require(ordering.firstIndex(of: regular))
        let boldIndex = try #require(ordering.firstIndex(of: bold))
        #expect(boldIndex > regularIndex)
    }

    @Test("All-caps text is not read as larger than it is")
    func recoversFontSizeForAllCaps() throws {
        // A run without lowercase letters has no x-height, so its dense band is
        // the cap height. Measured against the wrong ratio it reads about half
        // again too large.
        for fontSize in [24.0, 40.0] {
            let page = try render(
                "TOTAL AMOUNT",
                fontSize: fontSize,
                weight: .regular,
                foreground: .black,
                background: .white
            )
            let style = try #require(
                RecognizedTextStyleReader.style(
                    in: page.image,
                    region: page.region,
                    text: page.text
                )
            )
            #expect(abs(style.fontSize - fontSize) / fontSize < 0.25)
        }
    }

    @Test("A region with nothing in it reports no style")
    func blankRegionHasNoStyle() throws {
        let page = try render(
            "",
            fontSize: 40,
            weight: .regular,
            foreground: .black,
            background: .white
        )
        #expect(
            RecognizedTextStyleReader.style(in: page.image, region: page.region, text: page.text)
                == nil)
    }

    @Test("A region too small to hold glyphs reports no style")
    func tinyRegionHasNoStyle() throws {
        let page = try render(
            "Booking",
            fontSize: 40,
            weight: .regular,
            foreground: .black,
            background: .white
        )
        let sliver = CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001)
        #expect(
            RecognizedTextStyleReader.style(in: page.image, region: sliver, text: page.text) == nil
        )
    }

    // MARK: - Rendering

    private struct Page {
        let image: CGImage
        /// The drawn run's box, normalised with a top-left origin.
        let region: CGRect
        /// The characters drawn, which decide whether the dense band measured
        /// is an x-height or a cap height.
        let text: String
    }

    private func render(
        _ text: String,
        fontSize: Double,
        weight: NSFont.Weight,
        foreground: NSColor,
        background: NSColor,
        italic: Bool = false
    ) throws -> Page {
        let width = 900
        let height = 320
        var font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: fontSize) ?? font
        }
        // Draw at exactly one pixel per point so measured pixels are points,
        // whatever backing scale the test host happens to have.
        let representation = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            )
        )
        let context = try #require(NSGraphicsContext(bitmapImageRep: representation))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
        ]
        let origin = NSPoint(x: 40, y: 120)
        (text as NSString).draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let cgImage = try #require(representation.cgImage)

        // Box the run the way a recogniser does: from what was actually drawn,
        // with a little of the page around it. Deriving it from the point size
        // instead would clip the glyphs at larger sizes and make the reader
        // look wrong when the fixture was.
        let drawn = (text as NSString).size(withAttributes: attributes)
        let padding = 6.0
        let region = CGRect(
            x: (Double(origin.x) - padding) / Double(width),
            y: (Double(height) - Double(origin.y) - Double(drawn.height) - padding)
                / Double(height),
            width: (Double(drawn.width) + padding * 2) / Double(width),
            height: (Double(drawn.height) + padding * 2) / Double(height)
        )
        return Page(image: cgImage, region: region, text: text)
    }
}
