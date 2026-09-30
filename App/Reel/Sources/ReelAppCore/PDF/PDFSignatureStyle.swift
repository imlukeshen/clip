import AppKit
import CoreModel
import Foundation

/// A script face a typed signature can be rendered in.
///
/// Signatures are ordinary text layers rather than pasted images, so they stay
/// vector in the page, scale cleanly, and can be re-typed rather than redrawn.
public enum PDFSignatureStyle: String, CaseIterable, Sendable, Identifiable {
    case flowing
    case formal
    case casual
    case classic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flowing: "Flowing"
        case .formal: "Formal"
        case .casual: "Casual"
        case .classic: "Classic"
        }
    }

    /// Family shipped with macOS that carries this style.
    var familyName: String {
        switch self {
        case .flowing: "Snell Roundhand"
        case .formal: "Zapfino"
        case .casual: "Bradley Hand"
        case .classic: "Apple Chancery"
        }
    }

    /// Size this face needs to draw `text`, with room for its loops.
    ///
    /// Script faces overshoot their reported line height with swashes and long
    /// descenders, so the measured box is padded before it becomes a frame.
    func measure(_ text: String, atPointSize pointSize: Double) -> CGSize {
        let font =
            NSFont(name: fontDescriptor.postScriptName, size: pointSize)
            ?? .systemFont(ofSize: pointSize)
        let measured = NSAttributedString(string: text, attributes: [.font: font]).size()
        return CGSize(
            width: measured.width * 1.08,
            height: max(measured.height, pointSize) * 1.35
        )
    }

    /// The descriptor the renderer resolves, falling back when a face is absent.
    public var fontDescriptor: PDFFontDescriptor {
        let resolved = NSFont(name: familyName, size: 24)?.fontName ?? "Helvetica"
        return PDFFontDescriptor(postScriptName: resolved, familyName: familyName)
    }

    /// Whether the face is installed on this machine.
    public var isAvailable: Bool { NSFont(name: familyName, size: 24) != nil }
}
