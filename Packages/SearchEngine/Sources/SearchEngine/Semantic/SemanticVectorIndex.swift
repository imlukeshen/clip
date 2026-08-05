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
        return try await matches(vector: query.vector, model: query.model, limit: limit)
    }

    /// Finds chunks nearest to the mean embedding for an existing asset. The
    /// source asset is excluded so callers receive true library neighbours.
    public func matches(similarTo assetID: AssetID, limit: Int) async throws
        -> [SemanticTextMatch]
    {
        guard limit > 0 else { return [] }
        var candidates: [SemanticTextMatch] = []
        for model in await provider.currentModelIdentifiers().sorted() {
            let source = try await store.embeddings(for: assetID, model: model)
            guard let vector = Self.centroid(source.map(\.vector)) else { continue }
            candidates += try await matches(
                vector: vector,
                model: model,
                limit: limit * 2
            ).filter { $0.assetID != assetID }
        }
        return candidates.sorted(by: Self.matchOrdering).prefix(limit).map { $0 }
    }

    private func matches(vector: [Float], model: String, limit: Int) async throws
        -> [SemanticTextMatch]
    {
        let count = try await store.embeddingCount(model: model)
        guard count > 0 else { return [] }
        let generation = try await store.embeddingGeneration()
        if count <= Self.inMemoryChunkLimit {
            if cache?.model != model || cache?.generation != generation {
                let records = try await store.embeddings(model: model, limit: count)
                cache = Cache(model: model, generation: generation, records: records)
            }
            guard let cache else { return [] }
            return Self.rank(
                vector, metadata: cache.metadata, vectors: cache.vectors, limit: limit)
        }

        Self.logger.warning(
            "Semantic index has \(count, privacy: .public) chunks; paging from disk"
        )
        var offset = 0
        var candidates: [SemanticTextMatch] = []
        while offset < count {
            let records = try await store.embeddings(
                model: model,
                limit: Self.pageSize,
                offset: offset
            )
            guard !records.isEmpty else { break }
            let page = Cache(model: model, generation: generation, records: records)
            candidates += Self.rank(
                vector,
                metadata: page.metadata,
                vectors: page.vectors,
                limit: limit
            )
            candidates.sort(by: Self.matchOrdering)
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
        return matches.sorted(by: matchOrdering).prefix(limit).map { $0 }
    }

    private nonisolated static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let dimensions = vectors.first?.count, dimensions > 0,
            vectors.allSatisfy({ $0.count == dimensions })
        else { return nil }
        var result = [Float](repeating: 0, count: dimensions)
        for vector in vectors {
            for index in result.indices { result[index] += vector[index] }
        }
        let magnitude = sqrt(result.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return result.map { $0 / magnitude }
    }

    private nonisolated static func matchOrdering(
        _ lhs: SemanticTextMatch,
        _ rhs: SemanticTextMatch
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.assetID != rhs.assetID {
            return lhs.assetID.rawValue < rhs.assetID.rawValue
        }
        return (lhs.start ?? .zero) < (rhs.start ?? .zero)
    }
}
