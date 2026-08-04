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
