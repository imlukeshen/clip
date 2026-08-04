import Foundation

/// Broad media kinds used to filter the library.
public enum AssetKind: String, Codable, Sendable, CaseIterable {
    case video
    case image
    case audio
    case document
    /// Plain-text and source files edited in the text workspace — Markdown,
    /// LaTeX, code. Distinct from `.document`, which is reserved for PDFs and
    /// other rendered formats the app does not edit as text.
    case text
}
