import Foundation

/// The user-facing route that produced an ingest request.
public enum IngestSource: Sendable, Equatable {
    case inbox
    case pasteboard
    case drop
    case picker
}
