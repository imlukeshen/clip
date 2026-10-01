import CoreModel
import Foundation

/// Which mark a click landed on, and which of its regions.
///
/// The region matters because a mark can hold many: a batch redaction made
/// before each match became its own layer is one layer with a hundred and more
/// regions across the document. Selecting by layer alone made those
/// all-or-nothing, so one region placed wrongly could only be removed by taking
/// back every other redaction on the page.
public struct PDFMarkHit: Equatable, Sendable {
    public let layerID: PDFLayerID
    public let regionIndex: Int

    public init(layerID: PDFLayerID, regionIndex: Int) {
        self.layerID = layerID
        self.regionIndex = regionIndex
    }
}

/// Finds the redaction or highlight under a click.
///
/// Redactions and highlights had no hit target at all: the page's tap handler
/// resolved text and paragraphs and treated everything else as empty canvas, so
/// a click on one deselected instead of selecting it, and Delete had nothing to
/// remove. A mark that cannot be selected cannot be taken back, which matters
/// most for exactly the edit people most often want to undo.
public enum PDFMarkHitTest {
    /// How much slack a click gets, in normalized page units.
    ///
    /// A redaction over one line of body text is around 1% of the page tall, so
    /// without a margin it has to be hit within a couple of screen points.
    static let tolerance: CGFloat = 0.004

    /// The topmost mark containing `point`, or nil when none does.
    ///
    /// Topmost because a redaction sits over what it hides: a click inside one
    /// is aimed at the redaction, not at the paragraph underneath.
    public static func topmost(
        at point: CGPoint,
        in layers: [PDFLayer],
        rotation: PDFPageRotation
    ) -> PDFMarkHit? {
        for layer in layers.reversed() {
            let hit = regions(of: layer).firstIndex { region in
                displayBounds(region, rotation: rotation)
                    .insetBy(dx: -tolerance, dy: -tolerance)
                    .contains(point)
            }
            if let hit { return PDFMarkHit(layerID: layer.id, regionIndex: hit) }
        }
        return nil
    }

    /// The regions a mark occupies. Text layers are not marks and have none.
    public static func regions(of layer: PDFLayer) -> [CGRect] {
        switch layer {
        case .redaction(let redaction): redaction.regions
        case .highlight(let highlight): highlight.regions
        case .text: []
        }
    }

    /// Maps a stored rect into the space the rotated page is drawn in.
    public static func displayBounds(_ rect: CGRect, rotation: PDFPageRotation) -> CGRect {
        rotation.displayRect(for: rect)
    }
}
