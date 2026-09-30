import Foundation

/// A signature the user has adopted and can place again.
///
/// Adopting once and reusing is how signing a document actually works: a name
/// is typed once, kept, and stamped wherever it is needed. Only the name and
/// face are stored, never a rendered image, so a saved signature still scales
/// to whatever page it lands on.
public struct SavedSignature: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var style: PDFSignatureStyle

    public init(id: UUID = UUID(), name: String, style: PDFSignatureStyle) {
        self.id = id
        self.name = name
        self.style = style
    }
}
