import Foundation

/// Something the user copied, in the richest form the pasteboard offered.
///
/// The watcher reads one representation per change, preferring files over an
/// image over plain text, so a Finder copy becomes `.fileURLs` rather than the
/// path string that rides alongside it.
public enum ClipboardChange: Sendable, Equatable {
    /// A run of copied text.
    case text(String)
    /// Copied image bytes, with the file extension the bytes are encoded as.
    case image(Data, pathExtension: String)
    /// A set of copied file locations.
    case fileURLs([URL])
}
