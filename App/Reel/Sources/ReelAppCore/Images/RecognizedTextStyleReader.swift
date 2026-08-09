import CoreGraphics
import CoreModel
import Foundation

/// Reads back how a run of recognized text is drawn, from the pixels alone.
///
/// There is no API that names the font in a rasterised image, so this measures
/// the properties a replacement actually needs: the two colours present, how
/// tall the glyphs are, and how heavy their stems are. A replacement drawn
/// from those numbers in a system font reads as a correction rather than a
/// patch on flat artwork such as a screenshot.
public enum RecognizedTextStyleReader {
    /// Fraction of a system font's point size taken by its x-height.
    ///
    /// The dense band of a run is measured rather than its full ink extent,
    /// because the extent depends on whether the run happens to contain
    /// ascenders or descenders and would make the same text read as two
    /// different sizes.
    static let xHeightRatio = 0.52
    /// Fraction taken by its capitals. A run with no lowercase letters has no
    /// x-height, and its dense band is the cap height instead.
    static let capHeightRatio = 0.72
    /// Rows and columns of padding trimmed from the recognised box, which
    /// usually includes a little of the surrounding page.
    private static let insetFraction = 0.04

    /// Measures the style of the text inside `region`.
    ///
    /// - Parameters:
    ///   - image: The page the text sits on.
    ///   - region: The run's box, normalised to the image with a top-left
    ///     origin, as the recogniser reports it.
    ///   - text: The characters the recogniser read. A run without lowercase
    ///     letters measures its capitals rather than its x-height, and the two
    ///     ratios differ enough to matter.
    /// - Returns: The measured style, or `nil` when the region is too small or
    ///   too uniform to hold readable text.
    public static func style(
        in image: CGImage,
        region: CGRect,
        text: String
    ) -> RecognizedTextStyle? {
        guard let sample = Sample(image: image, region: region) else { return nil }
        guard let split = sample.split() else { return nil }

        let coverage = sample.rowCoverage(threshold: split.threshold, inkIsDark: split.inkIsDark)
        let band = Sample.xHeightBand(in: coverage)
        guard band.count > 1 else { return nil }
        let xHeight = Double(band.count)

        let stem = sample.medianStemWidth(
            in: band,
            threshold: split.threshold,
            inkIsDark: split.inkIsDark
        )
        let ratio = text.contains(where: \.isLowercase) ? xHeightRatio : capHeightRatio
        return RecognizedTextStyle(
            foreground: split.ink,
            background: split.page,
            fontSize: xHeight / ratio,
            weight: .matching(stemRatio: stem / xHeight)
        )
    }

    /// The intermediate measurements, exposed so thresholds can be calibrated
    /// against real renderings rather than guessed.
    static func rawMeasurements(
        in image: CGImage,
        region: CGRect
    ) -> (xHeight: Double, stemRatio: Double)? {
        guard let sample = Sample(image: image, region: region), let split = sample.split() else {
            return nil
        }
        let coverage = sample.rowCoverage(threshold: split.threshold, inkIsDark: split.inkIsDark)
        let band = Sample.xHeightBand(in: coverage)
        guard band.count > 1 else { return nil }
        let xHeight = Double(band.count)
        let stem = sample.medianStemWidth(
            in: band,
            threshold: split.threshold,
            inkIsDark: split.inkIsDark
        )
        return (xHeight, stem / xHeight)
    }

    /// The pixels of one recognised run, in straight sRGB.
    private struct Sample {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(image: CGImage, region: CGRect) {
            let clamped = region.standardized.intersection(
                CGRect(x: 0, y: 0, width: 1, height: 1)
            )
            guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
            let inset = clamped.insetBy(
                dx: clamped.width * RecognizedTextStyleReader.insetFraction,
                dy: clamped.height * RecognizedTextStyleReader.insetFraction
            )
            let source = inset.isNull || inset.height < 1e-6 ? clamped : inset
            let pixelRect = CGRect(
                x: source.minX * Double(image.width),
                y: source.minY * Double(image.height),
                width: source.width * Double(image.width),
                height: source.height * Double(image.height)
            ).integral
            width = max(Int(pixelRect.width), 0)
            height = max(Int(pixelRect.height), 0)
            guard width >= 4, height >= 4 else { return nil }

            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            guard
                let context = CGContext(
                    data: &buffer,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else { return nil }
            // Draw the whole page offset so the run lands on the origin, which
            // keeps the crop exact without building an intermediate image.
            context.draw(
                image,
                in: CGRect(
                    x: -pixelRect.minX,
                    y: -(Double(image.height) - pixelRect.maxY),
                    width: Double(image.width),
                    height: Double(image.height)
                )
            )
            pixels = buffer
        }

        func luminance(x: Int, y: Int) -> Double {
            let offset = (y * width + x) * 4
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }

        func colour(x: Int, y: Int) -> (Double, Double, Double) {
            let offset = (y * width + x) * 4
            return (
                Double(pixels[offset]) / 255,
                Double(pixels[offset + 1]) / 255,
                Double(pixels[offset + 2]) / 255
            )
        }

        /// Splits the run into ink and page.
        ///
        /// Text is two-toned, so an intensity threshold separates it cleanly.
        /// Which side is the page is decided by the border, not by area: a
        /// heavy headline can cover more of its box than the page does.
        func split() -> (threshold: Double, inkIsDark: Bool, ink: RGBA, page: RGBA)? {
            var histogram = [Int](repeating: 0, count: 64)
            for y in 0..<height {
                for x in 0..<width {
                    histogram[min(Int(luminance(x: x, y: y) * 64), 63)] += 1
                }
            }
            guard let threshold = Self.otsuThreshold(histogram) else { return nil }

            var borderDarker = 0
            var borderLighter = 0
            for x in 0..<width {
                for y in [0, height - 1] {
                    if luminance(x: x, y: y) < threshold {
                        borderDarker += 1
                    } else {
                        borderLighter += 1
                    }
                }
            }
            for y in 0..<height {
                for x in [0, width - 1] {
                    if luminance(x: x, y: y) < threshold {
                        borderDarker += 1
                    } else {
                        borderLighter += 1
                    }
                }
            }
            let inkIsDark = borderLighter >= borderDarker

            var inkSum = (0.0, 0.0, 0.0)
            var pageSum = (0.0, 0.0, 0.0)
            var inkCount = 0
            var pageCount = 0
            for y in 0..<height {
                for x in 0..<width {
                    let value = colour(x: x, y: y)
                    let isDark = luminance(x: x, y: y) < threshold
                    if isDark == inkIsDark {
                        inkSum = (inkSum.0 + value.0, inkSum.1 + value.1, inkSum.2 + value.2)
                        inkCount += 1
                    } else {
                        pageSum = (pageSum.0 + value.0, pageSum.1 + value.1, pageSum.2 + value.2)
                        pageCount += 1
                    }
                }
            }
            guard inkCount > 0, pageCount > 0 else { return nil }
            let ink = RGBA(
                r: inkSum.0 / Double(inkCount),
                g: inkSum.1 / Double(inkCount),
                b: inkSum.2 / Double(inkCount),
                a: 1
            )
            let page = RGBA(
                r: pageSum.0 / Double(pageCount),
                g: pageSum.1 / Double(pageCount),
                b: pageSum.2 / Double(pageCount),
                a: 1
            )
            return (threshold, inkIsDark, ink, page)
        }

        func isInk(x: Int, y: Int, threshold: Double, inkIsDark: Bool) -> Bool {
            (luminance(x: x, y: y) < threshold) == inkIsDark
        }

        /// Ink pixels per row.
        func rowCoverage(threshold: Double, inkIsDark: Bool) -> [Int] {
            (0..<height).map { y in
                (0..<width).reduce(0) { total, x in
                    total + (isInk(x: x, y: y, threshold: threshold, inkIsDark: inkIsDark) ? 1 : 0)
                }
            }
        }

        /// The rows holding the bodies of the glyphs.
        ///
        /// Ascenders and descenders reach only a few glyphs, so they leave a
        /// thin tail in the row profile. The bodies leave a dense block, which
        /// is the run's x-height whatever letters it happens to contain.
        static func xHeightBand(in coverage: [Int]) -> Range<Int> {
            let inked = coverage.filter { $0 > 0 }.sorted()
            guard !inked.isEmpty else { return 0..<0 }
            // Measure against the typical inked row rather than the busiest
            // one. The round letters in a run leave a spike, and at larger
            // sizes half of that spike sits above every ordinary row, which
            // would shrink the band to a few pixels.
            let median = Double(inked[inked.count / 2])
            let floor = max(median * 0.5, 1)
            // The longest unbroken stretch over that floor is the band of
            // bodies; ascenders and descenders leave shorter stretches.
            var best = 0..<0
            var start: Int?
            for row in 0...coverage.count {
                let isBody = row < coverage.count && Double(coverage[row]) >= floor
                if isBody {
                    if start == nil { start = row }
                } else if let began = start {
                    if row - began > best.count { best = began..<row }
                    start = nil
                }
            }
            return best
        }

        /// Median width of a horizontal ink run, which is a stem.
        ///
        /// The median rejects the long runs that crossbars and serifs produce
        /// while still describing the stroke the glyphs are drawn with.
        func medianStemWidth(in band: Range<Int>, threshold: Double, inkIsDark: Bool) -> Double {
            var runs: [Int] = []
            for y in band {
                var run = 0
                for x in 0..<width {
                    if isInk(x: x, y: y, threshold: threshold, inkIsDark: inkIsDark) {
                        run += 1
                    } else if run > 0 {
                        runs.append(run)
                        run = 0
                    }
                }
                if run > 0 { runs.append(run) }
            }
            guard !runs.isEmpty else { return 0 }
            runs.sort()
            return Double(runs[runs.count / 2])
        }

        /// Otsu's method: the intensity that best separates two populations.
        static func otsuThreshold(_ histogram: [Int]) -> Double? {
            let total = histogram.reduce(0, +)
            guard total > 0 else { return nil }
            let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
            var backgroundSum = 0.0
            var backgroundCount = 0
            var best = 0.0
            var bestBin = -1
            for (bin, count) in histogram.enumerated() {
                backgroundCount += count
                guard backgroundCount > 0, backgroundCount < total else {
                    backgroundSum += Double(bin * count)
                    continue
                }
                backgroundSum += Double(bin * count)
                let foregroundCount = total - backgroundCount
                let backgroundMean = backgroundSum / Double(backgroundCount)
                let foregroundMean = (sum - backgroundSum) / Double(foregroundCount)
                let between =
                    Double(backgroundCount) * Double(foregroundCount)
                    * (backgroundMean - foregroundMean) * (backgroundMean - foregroundMean)
                if between > best {
                    best = between
                    bestBin = bin
                }
            }
            guard bestBin >= 0, best > 0 else { return nil }
            return (Double(bestBin) + 0.5) / Double(histogram.count)
        }
    }
}
