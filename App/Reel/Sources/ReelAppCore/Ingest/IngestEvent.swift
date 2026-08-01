import Foundation
import LibraryStore

/// Progress and outcomes emitted by the ingest pipeline.
public enum IngestEvent: Sendable, Equatable {
    case started(URL)
    case progress(URL, Double)
    case finished(AssetRecord)
    case failed(URL, IngestError)
    case duplicate(AssetRecord)
}
