import Foundation

/// A durable stage in Clip's local media index.
public enum IndexStage: String, Codable, Sendable, CaseIterable, Hashable {
    case metadata
    case ocr
    case transcript
    case embedding
    case summary

    /// Stable dependency order for scheduling work on one asset.
    public var order: Int {
        switch self {
        case .metadata: 0
        case .ocr: 1
        case .transcript: 2
        case .embedding: 3
        case .summary: 4
        }
    }
}

/// The persisted lifecycle of an indexing stage.
public enum IndexJobState: String, Codable, Sendable, CaseIterable, Hashable {
    case pending
    case running
    case done
    case failed
    case skipped
}

/// One durable unit of indexing work.
public struct IndexJobRecord: Codable, Sendable, Equatable, Identifiable {
    public var assetID: AssetID
    public var stage: IndexStage
    public var state: IndexJobState
    public var attempts: Int
    public var error: String?
    public var updatedAt: Date

    public var id: String { "\(assetID.rawValue):\(stage.rawValue)" }

    public init(
        assetID: AssetID,
        stage: IndexStage,
        state: IndexJobState,
        attempts: Int,
        error: String?,
        updatedAt: Date
    ) {
        self.assetID = assetID
        self.stage = stage
        self.state = state
        self.attempts = attempts
        self.error = error
        self.updatedAt = updatedAt
    }
}

/// The part of the library whose index should be rebuilt.
public enum IndexScope: Sendable, Equatable {
    case all
    case assets(Set<AssetID>)
}

/// Dominant writing system used to select the appropriate FTS5 tokenizer.
public enum OCRScript: String, Codable, Sendable, Equatable {
    case alphabetic
    case cjk
    case mixed
}

/// One searchable text region visible in an image or over a video time range.
public struct OCRSpan: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64?
    public var assetID: AssetID
    public var start: RationalTime?
    public var end: RationalTime?
    public var text: String
    public var boundingBox: NormalizedRect
    public var confidence: Double
    public var revision: Int
    public var script: OCRScript

    public init(
        id: Int64? = nil,
        assetID: AssetID,
        start: RationalTime? = nil,
        end: RationalTime? = nil,
        text: String,
        boundingBox: NormalizedRect,
        confidence: Double,
        revision: Int,
        script: OCRScript
    ) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.end = end
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.revision = revision
        self.script = script
    }
}

/// One searchable phrase spoken during a media asset.
public struct TranscriptSpan: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64?
    public var assetID: AssetID
    public var start: RationalTime
    public var end: RationalTime
    public var text: String
    public var script: OCRScript

    public init(
        id: Int64? = nil,
        assetID: AssetID,
        start: RationalTime,
        end: RationalTime,
        text: String,
        script: OCRScript
    ) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.end = end
        self.text = text
        self.script = script
    }
}

/// Exact-text source returned by the durable keyword index.
public enum SearchHitSource: String, Codable, Sendable, Equatable, Hashable {
    case ocr
    case transcript
    case summary
    case filename
}

/// A raw BM25 match decoded by LibraryStore before asset-level fusion.
public struct IndexedTextMatch: Sendable, Equatable {
    public var assetID: AssetID
    public var source: SearchHitSource
    public var start: RationalTime?
    public var end: RationalTime?
    public var text: String
    public var rank: Double

    public init(
        assetID: AssetID,
        source: SearchHitSource,
        start: RationalTime? = nil,
        end: RationalTime? = nil,
        text: String,
        rank: Double
    ) {
        self.assetID = assetID
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.rank = rank
    }
}
