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

    public var isMissing: Bool { missingSince != nil }

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
        self.ingestState = ingestState
        self.missingSince = missingSince.map(Self.databaseDate)
    }

    private static func databaseDate(_ value: Date) -> Date {
        Date(timeIntervalSince1970: value.timeIntervalSince1970)
    }
}
