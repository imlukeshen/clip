import CoreModel
import Foundation
import LibraryStore
import SearchEngine
import Testing

@Suite("Semantic search")
struct SemanticSearchTests {
    @Test("Thirty-second chunks keep timestamps and stay within the model budget")
    func chunking() {
        let asset = semanticAsset(id: "chunked", name: "Walkthrough.mov")
        let longText = String(repeating: "x", count: SemanticChunker.maximumCharacters + 20)
        let chunks = SemanticChunker.chunks(
            asset: asset,
            ocr: [
                ocr(asset.id, text: "Subscription", start: 5, end: 10),
                ocr(asset.id, text: longText, start: 20, end: 25),
                ocr(asset.id, text: "Payment method", start: 35, end: 40),
            ],
            transcripts: [
                TranscriptSpan(
                    assetID: asset.id,
                    start: RationalTime(seconds: 6),
                    end: RationalTime(seconds: 9),
                    text: "customer account",
                    script: .alphabetic
                )
            ]
        )

        #expect(chunks.first?.kind == .filename)
        #expect(chunks.allSatisfy { $0.text.count <= SemanticChunker.maximumCharacters })
        #expect(chunks.contains { $0.kind == .ocr && $0.start == RationalTime(seconds: 5) })
        #expect(chunks.contains { $0.kind == .ocr && $0.start == RationalTime(seconds: 35) })
        #expect(chunks.contains { $0.kind == .transcript })
    }

    @Test("Concept search finds timestamped OCR without sharing query words")
    func semanticConceptMatch() async throws {
        let fixture = try await SemanticFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = ConceptEmbeddingProvider(model: "concept-v1")
        let processor = LocalIndexStageProcessor(store: fixture.store, embeddingProvider: provider)
        for asset in fixture.assets {
            _ = try await processor.process(assetID: asset.id, stage: .embedding)
        }
        let engine = SearchEngine(store: fixture.store, embeddingProvider: provider)

        let response = try await engine.search(
            SearchQuery(text: "the part where I set up billing", mode: .semantic)
        )

        let hit = try #require(response.hits.first)
        #expect(hit.assetID == fixture.assets[0].id)
        #expect(hit.moments.first?.start == RationalTime(seconds: 72))
        #expect(!String(hit.snippet.characters).localizedCaseInsensitiveContains("billing"))
    }

    @Test("A changed model is isolated and requests a safe reindex")
    func modelChange() async throws {
        let fixture = try await SemanticFixture(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldProvider = ConceptEmbeddingProvider(model: "concept-v1")
        let oldProcessor = LocalIndexStageProcessor(
            store: fixture.store,
            embeddingProvider: oldProvider
        )
        _ = try await oldProcessor.process(assetID: fixture.assets[0].id, stage: .embedding)

        let newProvider = ConceptEmbeddingProvider(model: "concept-v2")
        let engine = SearchEngine(store: fixture.store, embeddingProvider: newProvider)
        #expect(await engine.embeddingModelStatus().needsReindex)
        #expect(
            try await engine.search(SearchQuery(text: "billing", mode: .semantic)).hits.isEmpty
        )

        let newProcessor = LocalIndexStageProcessor(
            store: fixture.store,
            embeddingProvider: newProvider
        )
        _ = try await newProcessor.process(assetID: fixture.assets[0].id, stage: .embedding)

        #expect(!(await engine.embeddingModelStatus().needsReindex))
        #expect(
            try await engine.search(SearchQuery(text: "billing", mode: .semantic)).hits.first?
                .assetID == fixture.assets[0].id
        )
    }

    @Test("Apple contextual vectors are normalized and preserve a billing concept")
    func appleContextualEmbedding() async throws {
        let provider = NaturalLanguageEmbeddingProvider()
        let query: TextEmbedding
        do {
            query = try await provider.embedding(for: "the part where I set up billing")
        } catch TextEmbeddingError.assetsUnavailable {
            return
        }
        let related = try await provider.embedding(for: "Subscription Payment method")
        let unrelated = try await provider.embedding(for: "mountain landscape nature hiking")

        #expect(query.model == related.model)
        #expect(abs(magnitude(query.vector) - 1) < 0.000_1)
        #expect(dot(query.vector, related.vector) > dot(query.vector, unrelated.vector))
    }

    private func magnitude(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + $1 * $1 })
    }

    private func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

private struct ConceptEmbeddingProvider: TextEmbeddingProviding {
    let model: String

    func embedding(for text: String) async throws -> TextEmbedding {
        let lower = text.lowercased()
        let isBilling = ["billing", "subscription", "payment", "invoice"]
            .contains { lower.contains($0) }
        return TextEmbedding(vector: isBilling ? [1, 0] : [0, 1], model: model)
    }

    func currentModelIdentifiers() async -> Set<String> { [model] }
}

private struct SemanticFixture {
    let root: URL
    let store: LibraryStore
    let assets: [AssetRecord]

    init(assetCount: Int = 2) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-semantic-search-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        var records: [AssetRecord] = []
        for index in 0..<assetCount {
            let asset = semanticAsset(id: "semantic-\(index)", name: "Demo \(index).mov")
            let url = LibraryLayout.media(in: root).appendingPathComponent(asset.displayName)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("video-\(index)".utf8).write(to: url)
            var stored = asset
            stored.relativePath = "Media/\(asset.displayName)"
            try await store.insert(stored)
            if index == 0 {
                try await store.replaceOCRSpans(
                    [ocr(stored.id, text: "Subscription Payment method", start: 72, end: 80)],
                    for: stored.id
                )
            } else {
                try await store.replaceOCRSpans(
                    [ocr(stored.id, text: "Trail map and elevation", start: 12, end: 20)],
                    for: stored.id
                )
            }
            records.append(stored)
        }
        assets = records
    }
}

private func semanticAsset(id: String, name: String) -> AssetRecord {
    AssetRecord(
        id: AssetID(rawValue: id),
        relativePath: "Media/\(name)",
        displayName: name,
        kind: .video,
        createdAt: Date(timeIntervalSince1970: 1),
        importedAt: Date(timeIntervalSince1970: 1),
        byteSize: 1,
        contentHash: "hash-\(id)",
        duration: RationalTime(seconds: 120),
        ingestState: .ready
    )
}

private func ocr(
    _ assetID: AssetID,
    text: String,
    start: Double,
    end: Double
) -> OCRSpan {
    OCRSpan(
        assetID: assetID,
        start: RationalTime(seconds: start),
        end: RationalTime(seconds: end),
        text: text,
        boundingBox: NormalizedRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1),
        confidence: 0.95,
        revision: 3,
        script: .alphabetic
    )
}
