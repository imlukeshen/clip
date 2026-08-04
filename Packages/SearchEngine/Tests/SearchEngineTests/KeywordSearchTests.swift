import CoreModel
import Foundation
import LibraryStore
import SearchEngine
import Testing

@Suite("Keyword search")
struct KeywordSearchTests {
    @Test("Filters and quoted phrases parse without leaking into FTS")
    func queryParsing() throws {
        let parsed = try SearchQueryParser.parse(
            SearchQuery(
                text:
                    "kind:video after:2026-07-01 in:\"Client Demos\" duration:>1m hasAudio:true \"billing table\""
            )
        )

        #expect(parsed.mode == .keyword)
        #expect(parsed.phrases == ["billing table"])
        #expect(parsed.terms.isEmpty)
        #expect(parsed.filters.kind == .video)
        #expect(parsed.filters.folder == "Client Demos")
        #expect(parsed.filters.minimumDuration == RationalTime(seconds: 60))
        #expect(parsed.filters.hasAudio == true)
        #expect(parsed.filters.after != nil)
    }

    @Test("Queries over 512 characters are refused")
    func queryLengthBound() {
        #expect(throws: SearchError.queryTooLong) {
            try SearchQueryParser.parse(SearchQuery(text: String(repeating: "a", count: 513)))
        }
    }

    @Test("OCR and transcripts return grouped moments with filters")
    func groupedMomentSearch() async throws {
        let fixture = try await SearchFixture(count: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let billing = fixture.assets[0]
        try await fixture.store.replaceOCRSpans(
            [
                OCRSpan(
                    assetID: billing.id,
                    start: RationalTime(seconds: 192),
                    end: RationalTime(seconds: 197),
                    text: "Billing table",
                    boundingBox: NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
                    confidence: 0.94,
                    revision: 3,
                    script: .alphabetic
                )
            ],
            for: billing.id
        )
        try await fixture.store.replaceTranscriptSpans(
            [
                TranscriptSpan(
                    assetID: billing.id,
                    start: RationalTime(seconds: 45),
                    end: RationalTime(seconds: 48),
                    text: "customer renewal call",
                    script: .alphabetic
                )
            ],
            for: billing.id
        )
        let engine = SearchEngine(store: fixture.store)

        let response = try await engine.search(
            SearchQuery(text: "kind:video in:Demos \"billing table\"")
        )
        let hit = try #require(response.hits.first)
        #expect(hit.assetID == billing.id)
        #expect(hit.sources.contains(.ocr))
        #expect(hit.moments.first?.start == RationalTime(seconds: 192))

        let transcript = try await engine.search(SearchQuery(text: "renewal"))
        #expect(transcript.hits.first?.moments.first?.start == RationalTime(seconds: 45))
    }

    @Test("FTS punctuation is literal and two-character CJK falls back safely")
    func punctuationAndShortCJK() async throws {
        let fixture = try await SearchFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let asset = fixture.assets[0]
        try await fixture.store.replaceOCRSpans(
            [
                OCRSpan(
                    assetID: asset.id,
                    text: "C++ 請求設定",
                    boundingBox: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                    confidence: 0.9,
                    revision: 3,
                    script: .mixed
                )
            ],
            for: asset.id
        )
        let engine = SearchEngine(store: fixture.store)

        #expect(try await engine.search(SearchQuery(text: "C++")).hits.first?.assetID == asset.id)
        #expect(try await engine.search(SearchQuery(text: "請求")).hits.first?.assetID == asset.id)
    }

    @Test("Markdown content is indexed directly and returned as the strongest source")
    func directTextContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-text-search-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        let id = AssetID(rawValue: "release-notes")
        let contents = "# Release notes\n\nThe polished command palette ships today.\n"
        let url = LibraryLayout.inbox(in: root).appendingPathComponent("release-notes.md")
        try Data(contents.utf8).write(to: url)
        let asset = AssetRecord(
            id: id,
            relativePath: "Media/Inbox/release-notes.md",
            displayName: "release-notes.md",
            kind: .text,
            container: "md",
            createdAt: .now,
            importedAt: .now,
            byteSize: Int64(contents.utf8.count),
            contentHash: "release-notes-hash",
            ingestState: .ready
        )
        try await store.insert(asset)
        let processor = LocalIndexStageProcessor(store: store)

        #expect(try await processor.process(assetID: id, stage: .text) == .completed)
        let response = try await SearchEngine(store: store).search(
            SearchQuery(text: "\"polished command palette\"", mode: .keyword)
        )

        #expect(response.hits.first?.assetID == id)
        #expect(response.hits.first?.sources == [.text])
        #expect(
            response.hits.first.map { String($0.snippet.characters).contains("ships today") }
                == true
        )
    }

    @Test("Keyword retrieval stays under 150 ms over one thousand assets")
    func thousandAssetPerformance() async throws {
        let fixture = try await SearchFixture(count: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let engine = SearchEngine(store: fixture.store)
        let clock = ContinuousClock()

        let start = clock.now
        let response = try await engine.search(SearchQuery(text: "Screenshot 777"))
        let elapsed = start.duration(to: clock.now)

        #expect(response.hits.first?.assetID == fixture.assets[777].id)
        #expect(elapsed < .milliseconds(150))
    }
}

private struct SearchFixture {
    let root: URL
    let store: LibraryStore
    let assets: [AssetRecord]

    init(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-keyword-search-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        var assets: [AssetRecord] = []
        assets.reserveCapacity(count)
        for index in 0..<count {
            let id = AssetID(rawValue: String(format: "search-%04d", index))
            let filename = "Screenshot \(index).mov"
            let folder = index == 0 ? "Demos" : "Inbox"
            let url = LibraryLayout.media(in: root)
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(filename)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data("asset \(index)".utf8)
            try data.write(to: url)
            let date = Date(timeIntervalSince1970: 1_785_648_000 + Double(index))
            let asset = AssetRecord(
                id: id,
                relativePath: "Media/\(folder)/\(filename)",
                displayName: filename,
                kind: .video,
                container: "mov",
                codec: "h264",
                createdAt: date,
                importedAt: date,
                byteSize: Int64(data.count),
                contentHash: "search-hash-\(index)",
                width: 1_920,
                height: 1_080,
                duration: RationalTime(seconds: 300),
                nominalFPS: 60,
                hasAudio: true,
                ingestState: .ready
            )
            try await store.insert(asset)
            assets.append(asset)
        }
        self.root = root
        self.store = store
        self.assets = assets
    }
}
