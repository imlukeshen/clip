import CoreModel
import Foundation

/// Lightweight metadata used to list scratch buffers without loading their contents.
public struct ScratchTextRecord: Identifiable, Sendable, Equatable {
    /// The document identifier shared by the structure and content files.
    public var id: DocumentID
    /// The display name of the scratch buffer's first file.
    public var name: String
    /// The most recent modification date across both persisted files.
    public var modifiedAt: Date

    /// Creates scratch-buffer list metadata.
    public init(id: DocumentID, name: String, modifiedAt: Date) {
        self.id = id
        self.name = name
        self.modifiedAt = modifiedAt
    }
}
