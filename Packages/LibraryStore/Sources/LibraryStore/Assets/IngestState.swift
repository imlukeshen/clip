import Foundation

/// The durable state of an asset's ingest pipeline.
public enum IngestState: String, Codable, Sendable {
    case pending
    case ready
    case failed
}
