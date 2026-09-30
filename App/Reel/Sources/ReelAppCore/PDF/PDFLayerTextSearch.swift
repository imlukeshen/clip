import CoreGraphics
import CoreModel
import CoreText
import Foundation

/// Finds a string inside text the person added, rather than in the source PDF.
///
/// A PDF edit is not written back into the file until it is saved: replacing a
/// paragraph or dropping in a signature adds a ``PDFTextLayer`` drawn over the
/// page. Searching only the source glyphs therefore misses every word anyone has
/// typed in clipx — which is how "redact the word jiawei" answered that jiawei
/// was not in the document while it was plainly on screen in two places.
public enum PDFLayerTextSearch {
    /// Every occurrence of `query` in `layer`, with the rectangle it occupies.
    ///
    /// The layer frame covers the whole run, so for a word inside a longer line
    /// the substring is measured with the layer's own font and the frame divided
    /// proportionally. Redacting the frame instead would black out the sentence
    /// around the word.
    public static func matches(
        of query: String,
        in layer: PDFTextLayer
    ) -> [(rect: CGRect, snippet: String)] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !layer.text.isEmpty else { return [] }

        var results: [(rect: CGRect, snippet: String)] = []
        var searchStart = layer.text.startIndex
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        while searchStart < layer.text.endIndex,
            let found = layer.text.range(
                of: needle, options: options, range: searchStart..<layer.text.endIndex)
        {
            results.append((rect(for: found, in: layer), layer.text))
            searchStart = found.upperBound
        }
        return results
    }

    private static func rect(for range: Range<String.Index>, in layer: PDFTextLayer) -> CGRect {
        let total = width(of: layer.text, in: layer)
        guard total > 0 else { return layer.frame }
        let leading = width(
            of: String(layer.text[layer.text.startIndex..<range.lowerBound]), in: layer)
        let matched = width(of: String(layer.text[range]), in: layer)
        // Clamped so a measurement that disagrees with the stored frame — a font
        // that resolved differently from the one the frame was computed with —
        // cannot produce a rectangle outside the layer.
        let x = layer.frame.minX + layer.frame.width * min(leading / total, 1)
        let matchWidth = min(layer.frame.width * (matched / total), layer.frame.maxX - x)
        return CGRect(x: x, y: layer.frame.minY, width: matchWidth, height: layer.frame.height)
    }

    private static func width(of text: String, in layer: PDFTextLayer) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = CTFontCreateWithName(
            layer.font.postScriptName as CFString, layer.fontSize, nil)
        let attributed = NSAttributedString(
            string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        return CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }
}
