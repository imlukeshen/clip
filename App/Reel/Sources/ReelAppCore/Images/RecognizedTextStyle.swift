import CoreModel
import Foundation

/// How a run of text already on the page is drawn.
///
/// Replacing recognized text convincingly means matching what is there rather
/// than picking a default: the colour of the glyphs, the colour behind them,
/// how large they are, and how heavy their stems are.
///
/// What is deliberately absent is as considered as what is here. Slant is not
/// reported: measuring it from a rasterised run means separating the shear of
/// the glyphs from where the letters happen to sit, and across system-font
/// renderings at screenshot sizes the two are indistinguishable, so an italic
/// flag would be a coin toss. Weight is reported in two buckets for the same
/// reason — see `Weight`.
public struct RecognizedTextStyle: Equatable, Sendable {
    /// Weight buckets a replacement can be asked for.
    ///
    /// Only two. Stem width separates regular from bold across every size
    /// measured, but medium and semibold fall inside regular's spread once
    /// antialiasing rounds a stem to whole pixels, so offering four buckets
    /// would report a precision the pixels do not carry.
    public enum Weight: String, Equatable, Sendable, CaseIterable {
        case regular
        case bold

        /// Stem width as a fraction of the measured glyph height, above which
        /// a run reads as bold. Calibrated against system-font renderings from
        /// 16 to 40 points; see `RecognizedTextStyleReaderTests`.
        static let boldStemRatio = 0.25

        static func matching(stemRatio: Double) -> Weight {
            stemRatio >= boldStemRatio ? .bold : .regular
        }
    }

    /// Colour of the glyphs.
    public var foreground: RGBA
    /// Colour behind the glyphs, used to cover the original run.
    public var background: RGBA
    /// Point size, in the units of the image the run was measured in.
    public var fontSize: Double
    public var weight: Weight

    public init(
        foreground: RGBA,
        background: RGBA,
        fontSize: Double,
        weight: Weight
    ) {
        self.foreground = foreground
        self.background = background
        self.fontSize = fontSize
        self.weight = weight
    }
}
