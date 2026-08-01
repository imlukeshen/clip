import Foundation

/// Stable failures surfaced by the ingest pipeline.
public enum IngestError: Error, Sendable, Equatable {
    case neverStabilized(URL)
    case unreadable(URL, underlying: String)
    case unsupportedType(String)
    case zeroDuration(URL)
    case diskFull(needed: Int64)
    case bookmarkStale(key: String)
}
