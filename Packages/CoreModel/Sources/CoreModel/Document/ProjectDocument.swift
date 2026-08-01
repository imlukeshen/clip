import Foundation

/// A complete, deterministic, non-destructive Reel edit graph.
public struct ProjectDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: ProjectID
    public var name: String
    public var canvas: CanvasSpec
    public var timeline: Timeline
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        schemaVersion: Int = ProjectDocument.currentSchemaVersion,
        id: ProjectID,
        name: String,
        canvas: CanvasSpec = .fullHD,
        timeline: Timeline = Timeline(),
        createdAt: Date,
        modifiedAt: Date
    ) throws {
        guard schemaVersion <= ProjectDocument.currentSchemaVersion else {
            throw ModelError.schemaTooNew(
                found: schemaVersion,
                supported: ProjectDocument.currentSchemaVersion
            )
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.canvas = canvas
        self.timeline = timeline
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case canvas
        case timeline
        case createdAt
        case modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version <= ProjectDocument.currentSchemaVersion else {
            throw ModelError.schemaTooNew(
                found: version,
                supported: ProjectDocument.currentSchemaVersion
            )
        }
        schemaVersion = version
        id = try container.decode(ProjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        canvas = try container.decode(CanvasSpec.self, forKey: .canvas)
        timeline = try container.decode(Timeline.self, forKey: .timeline)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(timeline, forKey: .timeline)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }

    /// Decodes the canonical on-disk project representation.
    public static func decodeJSON(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }

    /// Encodes canonical, diff-friendly project JSON with a trailing newline.
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
