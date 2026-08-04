import CoreModel
import Foundation
import LibraryStore

/// Production stage processor for local metadata and on-device Vision OCR.
public struct LocalIndexStageProcessor: IndexStageProcessing {
    private let store: LibraryStore
    private let ocrIndexer: OCRIndexer

    public init(store: LibraryStore, ocrIndexer: OCRIndexer = OCRIndexer()) {
        self.store = store
        self.ocrIndexer = ocrIndexer
    }

    public func process(assetID: AssetID, stage: IndexStage) async throws -> IndexStageOutcome {
        switch stage {
        case .metadata:
            return .completed
        case .ocr:
            guard let asset = try await store.asset(id: assetID),
                asset.kind == .image || asset.kind == .video
            else { return .noContent }
            let url = try await store.url(for: assetID)
            let eventTrack = try? await store.eventTrack(for: assetID)
            let spans = try await ocrIndexer.index(
                asset: asset,
                url: url,
                eventTrack: eventTrack
            )
            try await store.replaceOCRSpans(spans, for: assetID)
            return spans.isEmpty ? .noContent : .completed
        case .transcript, .embedding, .summary:
            return .noContent
        }
    }
}
