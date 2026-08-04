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
        case .text:
            guard let asset = try await store.asset(id: assetID), asset.kind == .text else {
                return .noContent
            }
            let url = try await store.url(for: assetID)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let source = TextContentChunker.decode(data) else { return .noContent }
            let chunks = TextContentChunker.chunks(source).map { value in
                (text: value, script: OCRScriptDetector.detect(in: value))
            }
            try await store.replaceTextChunks(chunks, for: assetID)
            return chunks.isEmpty ? .noContent : .completed
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
                transcripts: try await store.transcriptSpans(for: assetID),
                text: try await store.textChunks(for: assetID)
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

/// Bounded, paragraph-aware chunks for directly searchable text files.
public enum TextContentChunker {
    public static let maximumBytes = 20 * 1_024 * 1_024
    public static let maximumCharacters = SemanticChunker.maximumCharacters
    public static let overlapCharacters = 512

    public static func decode(_ data: Data) -> String? {
        guard data.count <= maximumBytes else { return nil }
        let leading = [UInt8](data.prefix(3))
        if leading.count == 3, leading[0] == 0xEF, leading[1] == 0xBB,
            leading[2] == 0xBF
        {
            return String(data: Data(data.dropFirst(3)), encoding: .utf8)
        }
        if leading.count >= 2,
            (leading[0] == 0xFF && leading[1] == 0xFE)
                || (leading[0] == 0xFE && leading[1] == 0xFF)
        {
            return String(data: data, encoding: .utf16)
        }
        let sample = Data(data.prefix(8_192))
        if sample.contains(0) {
            guard let encoding = probableUTF16Encoding(sample) else { return nil }
            return String(data: data, encoding: encoding)
        }
        if let value = String(data: data, encoding: .utf8) { return value }
        return String(data: data, encoding: .isoLatin1)
    }

    public static func chunks(_ source: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentCount = 0
        for character in source {
            current.append(character)
            currentCount += 1
            if currentCount == maximumCharacters {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(current)
                }
                current = String(current.suffix(overlapCharacters))
                currentCount = current.count
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            result.last != current
        {
            result.append(current)
        }
        return result
    }

    private static func probableUTF16Encoding(_ data: Data) -> String.Encoding? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes.count.isMultiple(of: 2) else { return nil }
        let pairCount = bytes.count / 2
        let evenNulls = stride(from: 0, to: bytes.count, by: 2).count { bytes[$0] == 0 }
        let oddNulls = stride(from: 1, to: bytes.count, by: 2).count { bytes[$0] == 0 }
        let highNullThreshold = max(2, pairCount / 3)
        let lowNullThreshold = pairCount / 20
        if evenNulls >= highNullThreshold, oddNulls <= lowNullThreshold {
            return .utf16BigEndian
        }
        if oddNulls >= highNullThreshold, evenNulls <= lowNullThreshold {
            return .utf16LittleEndian
        }
        return nil
    }
}
