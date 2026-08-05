import CoreModel
import Foundation

/// A restored scratch document and its decoded editable contents.
public struct ScratchTextBuffer: Sendable, Equatable {
    /// The structural editor document persisted beside the content file.
    public let document: TextDocument
    /// The decoded contents and original text format.
    public let contents: LoadedTextFile

    /// Creates a restored scratch buffer.
    public init(document: TextDocument, contents: LoadedTextFile) {
        self.document = document
        self.contents = contents
    }
}
