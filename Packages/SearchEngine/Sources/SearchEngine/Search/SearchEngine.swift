import CoreModel
import Foundation
import LibraryStore

/// Local hybrid-search facade. S2 supplies keyword retrieval; S4 adds semantic
/// candidates to this same asset-level fusion point.
public actor SearchEngine {
    private let store: LibraryStore
    private let semanticIndex: SemanticVectorIndex

    public init(
        store: LibraryStore,
        embeddingProvider: any TextEmbeddingProviding = NaturalLanguageEmbeddingProvider()
    ) {
        self.store = store
        self.semanticIndex = SemanticVectorIndex(store: store, provider: embeddingProvider)
    }

    public func search(_ query: SearchQuery) async throws -> SearchResponse {
        let parsed = try SearchQueryParser.parse(query)
        let assets = try await store.assets(kind: nil, limit: Int.max, offset: 0)
        let filtered = assets.filter { assetMatches($0, filters: parsed.filters) }
        let runsSemantic = parsed.mode != .keyword && parsed.phrases.isEmpty
        let runsKeyword = parsed.mode != .semantic
        let isComplete = try await store.isTextIndexComplete(includeEmbeddings: runsSemantic)
        let limit = min(max(query.limit, 1), 500)

        guard !parsed.isEmpty else {
            return SearchResponse(
                hits: filtered.prefix(limit).enumerated().map { index, asset in
                    SearchHit(
                        assetID: asset.id,
                        score: 1 / Double(index + 1),
                        moments: [],
                        snippet: AttributedString(asset.displayName),
                        sources: [.filename],
                        isUnavailable: asset.isMissing
                    )
                },
                isComplete: isComplete
            )
        }

        let candidateLimit = min(max(limit * 20, 200), 10_000)
        let rawMatches =
            runsKeyword
            ? try await store.keywordMatches(
                terms: parsed.terms,
                phrases: parsed.phrases,
                limit: candidateLimit
            ) : []
        let allowed = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        let highlightTerms = parsed.terms + parsed.phrases
        var buckets: [AssetID: HitBucket] = [:]
        let bySource = Dictionary(grouping: rawMatches, by: \.source)
        for (source, sourceMatches) in bySource {
            for (rank, match) in sourceMatches.sorted(by: matchOrdering).enumerated() {
                guard allowed[match.assetID] != nil else { continue }
                var bucket = buckets[match.assetID] ?? HitBucket()
                bucket.score += sourceWeight(source) / Double(60 + rank + 1)
                bucket.sources.insert(source)
                if let start = match.start {
                    let moment = SearchMoment(
                        assetID: match.assetID,
                        start: start,
                        end: match.end,
                        snippet: highlighted(match.text, terms: highlightTerms),
                        source: source
                    )
                    if !bucket.moments.contains(where: { $0.id == moment.id }) {
                        bucket.moments.append(moment)
                    }
                }
                if bucket.snippet == nil || source != .filename {
                    bucket.snippet = highlighted(match.text, terms: highlightTerms)
                }
                buckets[match.assetID] = bucket
            }
        }

        if runsSemantic {
            let semanticText = parsed.terms.joined(separator: " ")
            if !semanticText.isEmpty,
                let semanticMatches = try? await semanticIndex.matches(
                    text: semanticText,
                    limit: candidateLimit
                )
            {
                for (rank, match) in semanticMatches.enumerated() {
                    guard allowed[match.assetID] != nil else { continue }
                    var bucket = buckets[match.assetID] ?? HitBucket()
                    bucket.score += sourceWeight(match.kind) * 0.85 / Double(60 + rank + 1)
                    bucket.sources.insert(match.kind)
                    if let start = match.start {
                        let moment = SearchMoment(
                            assetID: match.assetID,
                            start: start,
                            end: match.end,
                            snippet: AttributedString(match.text),
                            source: match.kind
                        )
                        if !bucket.moments.contains(where: { $0.id == moment.id }) {
                            bucket.moments.append(moment)
                        }
                    }
                    if bucket.snippet == nil { bucket.snippet = AttributedString(match.text) }
                    buckets[match.assetID] = bucket
                }
            }
        }

        let hits = buckets.compactMap { assetID, bucket -> SearchHit? in
            guard let asset = allowed[assetID] else { return nil }
            return SearchHit(
                assetID: assetID,
                score: bucket.score,
                moments: bucket.moments.sorted { $0.start < $1.start },
                snippet: bucket.snippet ?? AttributedString(asset.displayName),
                sources: bucket.sources,
                isUnavailable: asset.isMissing
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = allowed[$0.assetID]?.createdAt ?? .distantPast
            let rhs = allowed[$1.assetID]?.createdAt ?? .distantPast
            return lhs > rhs
        }
        return SearchResponse(hits: Array(hits.prefix(limit)), isComplete: isComplete)
    }

    public func searchWithin(_ assetID: AssetID, text: String) async throws -> [SearchMoment] {
        let parsed = try SearchQueryParser.parse(SearchQuery(text: text, limit: 500))
        guard !parsed.isEmpty else { return [] }
        var moments: [SearchMoment] = []
        if parsed.mode != .semantic {
            moments += try await store.keywordMatches(
                terms: parsed.terms,
                phrases: parsed.phrases,
                limit: 2_000
            )
            .filter { $0.assetID == assetID && $0.start != nil }
            .compactMap { match in
                guard let start = match.start else { return nil }
                return SearchMoment(
                    assetID: assetID,
                    start: start,
                    end: match.end,
                    snippet: highlighted(match.text, terms: parsed.terms + parsed.phrases),
                    source: match.source
                )
            }
        }
        if parsed.mode != .keyword {
            let semanticText = parsed.terms.joined(separator: " ")
            if !semanticText.isEmpty,
                let semantic = try? await semanticIndex.matches(text: semanticText, limit: 2_000)
            {
                let matchingAsset = semantic.filter { $0.assetID == assetID }
                for match in matchingAsset {
                    guard let start = match.start else { continue }
                    moments.append(
                        SearchMoment(
                            assetID: assetID,
                            start: start,
                            end: match.end,
                            snippet: AttributedString(match.text),
                            source: match.kind
                        )
                    )
                }
            }
        }
        return Dictionary(grouping: moments, by: \.id).compactMap(\.value.first)
            .sorted { $0.start < $1.start }
    }

    public func textAt(_ assetID: AssetID, time: RationalTime) async throws -> [OCRSpan] {
        try await store.ocrSpans(for: assetID, at: time)
    }

    /// Returns the closest other assets using the indexed semantic chunks for
    /// `assetID` as the query. Results retain their best timestamped moments.
    public func similar(to assetID: AssetID, limit: Int = 20) async throws -> [SearchHit] {
        let resultLimit = min(max(limit, 1), 100)
        let assets = try await store.assets(kind: nil, limit: Int.max, offset: 0)
        let allowed = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let matches = try await semanticIndex.matches(
            similarTo: assetID,
            limit: min(max(resultLimit * 20, 200), 2_000)
        )
        var buckets: [AssetID: HitBucket] = [:]
        for match in matches where match.assetID != assetID {
            guard allowed[match.assetID] != nil else { continue }
            var bucket = buckets[match.assetID] ?? HitBucket()
            bucket.score = max(bucket.score, Double(match.score))
            bucket.sources.insert(match.kind)
            if let start = match.start {
                let moment = SearchMoment(
                    assetID: match.assetID,
                    start: start,
                    end: match.end,
                    snippet: AttributedString(match.text),
                    source: match.kind
                )
                if bucket.moments.count < 5,
                    !bucket.moments.contains(where: { $0.id == moment.id })
                {
                    bucket.moments.append(moment)
                }
            }
            if bucket.snippet == nil { bucket.snippet = AttributedString(match.text) }
            buckets[match.assetID] = bucket
        }
        return buckets.compactMap { id, bucket in
            guard let asset = allowed[id] else { return nil }
            return SearchHit(
                assetID: id,
                score: bucket.score,
                moments: bucket.moments.sorted { $0.start < $1.start },
                snippet: bucket.snippet ?? AttributedString(asset.displayName),
                sources: bucket.sources,
                isUnavailable: asset.isMissing
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.assetID.rawValue < $1.assetID.rawValue
        }
        .prefix(resultLimit).map { $0 }
    }

    public func embeddingModelStatus() async -> EmbeddingIndexStatus {
        await semanticIndex.modelStatus()
    }

    private struct HitBucket {
        var score = 0.0
        var moments: [SearchMoment] = []
        var snippet: AttributedString?
        var sources: Set<SearchHitSource> = []
    }

    private func assetMatches(_ asset: AssetRecord, filters: SearchFilters) -> Bool {
        if let kind = filters.kind, asset.kind != kind { return false }
        if let after = filters.after, asset.createdAt < after { return false }
        if let before = filters.before, asset.createdAt > before { return false }
        if let folder = filters.folder,
            !asset.relativePath.localizedCaseInsensitiveContains(folder)
        {
            return false
        }
        if let minimum = filters.minimumDuration,
            (asset.duration ?? .zero) < minimum
        {
            return false
        }
        if let maximum = filters.maximumDuration,
            (asset.duration ?? .zero) > maximum
        {
            return false
        }
        if let hasAudio = filters.hasAudio, asset.hasAudio != hasAudio { return false }
        return true
    }

    private func matchOrdering(_ lhs: IndexedTextMatch, _ rhs: IndexedTextMatch) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.assetID != rhs.assetID { return lhs.assetID.rawValue < rhs.assetID.rawValue }
        return (lhs.start ?? .zero) < (rhs.start ?? .zero)
    }

    private func sourceWeight(_ source: SearchHitSource) -> Double {
        switch source {
        case .text: 1.6
        case .ocr: 1.35
        case .transcript: 1.25
        case .filename: 1
        case .summary: 0.7
        }
    }

    private func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString(text)
        for term in terms where !term.isEmpty {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                let range = result[searchStart...].range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            {
                result[range].inlinePresentationIntent = .stronglyEmphasized
                searchStart = range.upperBound
            }
        }
        return result
    }
}
