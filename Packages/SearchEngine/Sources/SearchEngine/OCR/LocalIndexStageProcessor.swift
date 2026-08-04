import CoreModel
import Foundation
import LibraryStore

/// Production stage processor for local metadata and on-device Vision OCR.
public struct LocalIndexStageProcessor: IndexStageProcessing {
    private let store: LibraryStore
    private let ocrIndexer: OCRIndexer
    private let embeddingProvider: any TextEmbeddingProviding

    public init(
        store: LibraryStore,
        ocrIndexer: OCRIndexer = OCRIndexer(),
        embeddingProvider: any TextEmbeddingProviding = NaturalLanguageEmbeddingProvider()
    ) {
        self.store = store
        self.ocrIndexer = ocrIndexer
        self.embeddingProvider = embeddingProvider
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
        case .embedding:
            guard let asset = try await store.asset(id: assetID) else { return .noContent }
            let chunks = SemanticChunker.chunks(
                asset: asset,
                ocr: try await store.ocrSpans(for: assetID),
                transcripts: try await store.transcriptSpans(for: assetID)
            )
            var records: [EmbeddingRecord] = []
            var skippedUnavailableModel = false
            records.reserveCapacity(chunks.count)
            for chunk in chunks {
                do {
                    let embedded = try await embeddingProvider.embedding(for: chunk.text)
                    records.append(
                        EmbeddingRecord(
                            assetID: assetID,
                            chunkIndex: chunk.index,
                            kind: chunk.kind,
                            start: chunk.start,
                            end: chunk.end,
                            text: chunk.text,
                            vector: embedded.vector,
                            model: embedded.model
                        )
                    )
                } catch TextEmbeddingError.assetsUnavailable {
                    skippedUnavailableModel = true
                    continue
                }
            }
            try await store.replaceEmbeddings(
                records,
                for: assetID,
                removingOtherModels: !skippedUnavailableModel
            )
            return records.isEmpty ? .noContent : .completed
        case .transcript, .summary:
            return .noContent
        }
    }
}
