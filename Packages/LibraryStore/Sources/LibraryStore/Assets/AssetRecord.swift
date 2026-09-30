import CoreModel
import Foundation

/// Durable metadata for one immutable file in the library.
public struct AssetRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: AssetID
    public var relativePath: String
    public var displayName: String
    public var kind: AssetKind
    public var container: String?
    public var codec: String?
    public var createdAt: Date
    public var importedAt: Date
    public var byteSize: Int64
    public var contentHash: String
    public var width: Int?
    public var height: Int?
    public var duration: RationalTime?
    public var nominalFPS: Double?
    public var isVariableFPS: Bool
    public var hasAudio: Bool
    public var preferredTransform: JSONValue?
    public var eventTrackPath: String?
    public var eventAlignment: EventAlignmentKind?
    public var thumbnailPath: String?
    public var peaksPath: String?
    public var ingestState: IngestState
    public var missingSince: Date?
    /// Bookmark key for a file the library references rather than owns.
    ///
    /// Nil means the file was copied into the library, which owns those bytes.
    /// Non-nil means it stayed where the user had it and is reached through a
    /// security-scoped bookmark, so edits save back to the original file
    /// (ADR-0013). `relativePath` then records where it was last seen, for
    /// display and for recovery when a bookmark cannot be resolved.
    public var externalBookmarkKey: String?

    public var isMissing: Bool { missingSince != nil }

    /// Whether the library points at this file rather than owning a copy.
    public var isReferenced: Bool { externalBookmarkKey != nil }

    public init(
        id: AssetID,
        relativePath: String,
        displayName: String,
        kind: AssetKind,
        container: String? = nil,
        codec: String? = nil,
        createdAt: Date,
        importedAt: Date,
        byteSize: Int64,
        contentHash: String,
        width: Int? = nil,
        height: Int? = nil,
        duration: RationalTime? = nil,
        nominalFPS: Double? = nil,
        isVariableFPS: Bool = false,
        hasAudio: Bool = false,
        preferredTransform: JSONValue? = nil,
        eventTrackPath: String? = nil,
        eventAlignment: EventAlignmentKind? = nil,
        thumbnailPath: String? = nil,
        peaksPath: String? = nil,
        externalBookmarkKey: String? = nil,
        ingestState: IngestState,
        missingSince: Date? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.displayName = displayName
        self.kind = kind
        self.container = container
        self.codec = codec
        // SQLite stores these as Unix-epoch doubles. Canonicalize at the model
        // boundary so a write/read cycle preserves exact value identity.
        self.createdAt = Self.databaseDate(createdAt)
        self.importedAt = Self.databaseDate(importedAt)
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.width = width
        self.height = height
        self.duration = duration
        self.nominalFPS = nominalFPS
        self.isVariableFPS = isVariableFPS
        self.hasAudio = hasAudio
        self.preferredTransform = preferredTransform
        self.eventTrackPath = eventTrackPath
        self.eventAlignment = eventAlignment
        self.thumbnailPath = thumbnailPath
        self.peaksPath = peaksPath
        self.externalBookmarkKey = externalBookmarkKey
        self.ingestState = ingestState
        self.missingSince = missingSince.map(Self.databaseDate)
    }

    private static func databaseDate(_ value: Date) -> Date {
        Date(timeIntervalSince1970: value.timeIntervalSince1970)
    }
}
