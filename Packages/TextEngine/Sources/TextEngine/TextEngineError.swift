import CoreModel
import Foundation

/// Failures produced while loading, decoding, or writing text files.
///
/// One error enum per package, per the project conventions. Highlighting, LaTeX
/// compilation, and Markdown rendering (T1–T3) surface their failures through
/// additional cases added here as they land.
public enum TextEngineError: Error, Sendable, Equatable {
    /// The file's bytes could not be decoded with any candidate encoding.
    case undecodable(URL)
    /// The file could not be read from disk.
    case unreadable(URL)
    /// The text could not be encoded back to bytes for writing.
    case unencodable(TextEncoding)
    /// The file exceeds the largest size the editor will open in one buffer.
    case tooLarge(URL, byteSize: Int64, limit: Int64)
    /// A persisted scratch-buffer record is incomplete or malformed.
    case invalidScratchBuffer(URL)
}
