import Accelerate
import CoreModel
import Foundation
import LibraryStore
import OSLog

/// Brute-force cosine index optimized for personal-library scale.
public actor SemanticVectorIndex {
    public static let inMemoryChunkLimit = 200_000
    private static let pageSize = 5_000
    private static let logger = Logger(subsystem: "com.clip.search", category: "semantic-index")

    private let store: LibraryStore
    private let provider: any TextEmbeddingProviding
    private var cache: Cache?

    public init(store: LibraryStore, provider: any TextEmbeddingProviding) {
        self.store = store
        self.provider = provider
    }

    public func matches(text: String, limit: Int) async throws -> [SemanticTextMatch] {
        guard limit > 0 else { return [] }
        let query = try await provider.embedding(for: text)
        let count = try await store.embeddingCount(model: query.model)
        guard count > 0 else { return [] }
        let generation = try await store.embeddingGeneration()
        if count <= Self.inMemoryChunkLimit {
            if cache?.model != query.model || cache?.generation != generation {
                let records = try await store.embeddings(model: query.model, limit: count)
                cache = Cache(model: query.model, generation: generation, records: records)
            }
            guard let cache else { return [] }
            return Self.rank(
                query.vector, metadata: cache.metadata, vectors: cache.vectors, limit: limit)
        }

        Self.logger.warning(
            "Semantic index has \(count, privacy: .public) chunks; paging from disk"
        )
        var offset = 0
        var candidates: [SemanticTextMatch] = []
        while offset < count {
            let records = try await store.embeddings(
                model: query.model,
                limit: Self.pageSize,
                offset: offset
            )
            guard !records.isEmpty else { break }
            let page = Cache(model: query.model, generation: generation, records: records)
            candidates += Self.rank(
                query.vector,
                metadata: page.metadata,
                vectors: page.vectors,
                limit: limit
            )
            candidates.sort { $0.score > $1.score }
            if candidates.count > limit { candidates.removeLast(candidates.count - limit) }
            offset += records.count
        }
        return candidates
    }

    public func modelStatus() async -> EmbeddingIndexStatus {
        let current = await provider.currentModelIdentifiers()
        let indexed = (try? await store.embeddingModels()) ?? []
        return EmbeddingIndexStatus(currentModels: current, indexedModels: indexed)
    }

    private struct Metadata: Sendable {
        var assetID: AssetID
        var kind: SearchHitSource
        var start: RationalTime?
        var end: RationalTime?
        var text: String
        var offset: Int
        var dimensions: Int
    }

    private struct Cache: Sendable {
        var model: String
        var generation: Int64
        var metadata: [Metadata]
        var vectors: [Float]

        init(model: String, generation: Int64, records: [EmbeddingRecord]) {
            self.model = model
            self.generation = generation
            var metadata: [Metadata] = []
            var vectors: [Float] = []
            vectors.reserveCapacity(records.reduce(0) { $0 + $1.dimensions })
            for record in records {
                metadata.append(
                    Metadata(
                        assetID: record.assetID,
                        kind: record.kind,
                        start: record.start,
                        end: record.end,
                        text: record.text,
                        offset: vectors.count,
                        dimensions: record.dimensions
                    )
                )
                vectors.append(contentsOf: record.vector)
            }
            self.metadata = metadata
            self.vectors = vectors
        }
    }

    private nonisolated static func rank(
        _ query: [Float],
        metadata: [Metadata],
        vectors: [Float],
        limit: Int
    ) -> [SemanticTextMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [SemanticTextMatch] = []
        matches.reserveCapacity(min(metadata.count, limit * 2))
        query.withUnsafeBufferPointer { queryBuffer in
            vectors.withUnsafeBufferPointer { vectorBuffer in
                guard let queryBase = queryBuffer.baseAddress,
                    let vectorBase = vectorBuffer.baseAddress
                else { return }
                for item in metadata where item.dimensions == query.count {
                    var score: Float = 0
                    vDSP_dotpr(
                        queryBase,
                        1,
                        vectorBase.advanced(by: item.offset),
                        1,
                        &score,
                        vDSP_Length(item.dimensions)
                    )
                    guard score.isFinite else { continue }
                    matches.append(
                        SemanticTextMatch(
                            assetID: item.assetID,
                            kind: item.kind,
                            start: item.start,
                            end: item.end,
                            text: item.text,
                            score: score
                        )
                    )
                }
            }
        }
        return matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.assetID != $1.assetID { return $0.assetID.rawValue < $1.assetID.rawValue }
            return ($0.start ?? .zero) < ($1.start ?? .zero)
        }.prefix(limit).map { $0 }
    }
}
