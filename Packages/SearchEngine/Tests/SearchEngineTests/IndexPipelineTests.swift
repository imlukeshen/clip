import CoreModel
import Foundation
import LibraryStore
import SearchEngine
import Testing

@Suite("Resumable index pipeline")
struct IndexPipelineTests {
    @Test("One hundred jobs resume after a quit without duplicates")
    func jobsResumeAfterQuit() async throws {
        let fixture = try await Fixture(assetCount: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for asset in fixture.assets {
            try await fixture.store.enqueueIndexJobs(for: asset.id, stages: [.metadata])
        }

        let firstProcessor = CountingProcessor(stallsAfter: 20)
        let firstPipeline = IndexPipeline(
            store: fixture.store,
            processor: firstProcessor,
            retryDelay: .milliseconds(10)
        )
        await firstPipeline.resumePending()
        try await waitUntil {
            try await fixture.store.indexJobs().count { $0.state == .done } >= 20
        }
        await firstPipeline.stop()

        let secondProcessor = CountingProcessor()
        let secondPipeline = IndexPipeline(
            store: fixture.store,
            processor: secondProcessor,
            retryDelay: .milliseconds(10)
        )
        await secondPipeline.resumePending()
        try await waitUntil {
            try await fixture.store.indexJobs().allSatisfy { $0.state == .done }
        }
        await secondPipeline.stop()

        let jobs = try await fixture.store.indexJobs()
        #expect(jobs.count == 100)
        #expect(jobs.allSatisfy { $0.state == .done && $0.attempts == 0 })
        #expect(await firstProcessor.uniqueCompletedCount() == 20)
        #expect(await secondProcessor.uniqueCompletedCount() == 80)
    }

    @Test("Playback pauses indexing before any work begins")
    func playbackPausesIndexing() async throws {
        let fixture = try await Fixture(assetCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processor = CountingProcessor()
        let pipeline = IndexPipeline(
            store: fixture.store,
            processor: processor,
            retryDelay: .milliseconds(10)
        )

        await pipeline.setPauseReasons([.playback])
        for asset in fixture.assets {
            await pipeline.enqueue(asset.id, stages: [.metadata])
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await processor.callCount() == 0)
        #expect(try await fixture.store.indexJobs().allSatisfy { $0.state == .pending })

        await pipeline.setPauseReasons([])
        try await waitUntil {
            try await fixture.store.indexJobs().allSatisfy { $0.state == .done }
        }
        await pipeline.stop()
        #expect(await processor.callCount() == 3)
    }

    @Test("A stage stops retrying after three real failures")
    func failuresAreBounded() async throws {
        struct ExpectedFailure: Error {}
        let fixture = try await Fixture(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = Counter()
        let processor = AnyIndexStageProcessor { _, _ in
            await calls.increment()
            throw ExpectedFailure()
        }
        let pipeline = IndexPipeline(
            store: fixture.store,
            processor: processor,
            retryDelay: .milliseconds(10)
        )

        await pipeline.enqueue(fixture.assets[0].id, stages: [.metadata])
        try await waitUntil {
            try await fixture.store.indexJobs().first?.state == .failed
        }
        await pipeline.stop()

        let job = try #require(try await fixture.store.indexJobs().first)
        #expect(job.attempts == 3)
        #expect(await calls.value == 3)
    }

    @Test("Reindex replaces a completed stage")
    func reindexReplacesCompletedStage() async throws {
        let fixture = try await Fixture(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processor = CountingProcessor()
        let pipeline = IndexPipeline(
            store: fixture.store,
            processor: processor,
            retryDelay: .milliseconds(10)
        )
        let assetID = fixture.assets[0].id

        await pipeline.enqueue(assetID, stages: [.embedding])
        try await waitUntil { await processor.callCount() == 1 }
        try await waitUntil {
            try await fixture.store.indexJobs().first?.state == .done
        }

        await pipeline.reindex(assetID, stages: [.embedding])
        try await waitUntil { await processor.callCount() == 2 }
        try await waitUntil {
            try await fixture.store.indexJobs().first?.state == .done
        }
        await pipeline.stop()

        let jobs = try await fixture.store.indexJobs()
        #expect(jobs.count == 1)
        #expect(jobs[0].assetID == assetID)
        #expect(jobs[0].stage == .embedding)
        #expect(jobs[0].state == .done)
    }

    @Test("Serious thermal pressure defers all stages")
    func thermalPressureDefersWork() async throws {
        let fixture = try await Fixture(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processor = CountingProcessor()
        let pipeline = IndexPipeline(
            store: fixture.store,
            processor: processor,
            resourceSnapshot: {
                IndexResourceSnapshot(
                    thermalLevel: .serious,
                    isLowPowerModeEnabled: false
                )
            },
            retryDelay: .seconds(60)
        )

        await pipeline.enqueue(fixture.assets[0].id, stages: [.metadata])
        try await Task.sleep(for: .milliseconds(80))
        await pipeline.stop()

        #expect(await processor.callCount() == 0)
        #expect(try await fixture.store.indexJobs().first?.state == .pending)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor CountingProcessor: IndexStageProcessing {
    private var calls: [AssetID] = []
    private let stallsAfter: Int?

    init(stallsAfter: Int? = nil) {
        self.stallsAfter = stallsAfter
    }

    func process(assetID: AssetID, stage: IndexStage) async throws -> IndexStageOutcome {
        if let stallsAfter, calls.count >= stallsAfter {
            try await Task.sleep(for: .seconds(3_600))
        }
        calls.append(assetID)
        return .completed
    }

    func callCount() -> Int { calls.count }
    func uniqueCompletedCount() -> Int { Set(calls).count }
}

private struct Fixture {
    let root: URL
    let store: LibraryStore
    let assets: [AssetRecord]

    init(assetCount: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-index-pipeline-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        var assets: [AssetRecord] = []
        for index in 0..<assetCount {
            let id = AssetID(rawValue: String(format: "asset-%03d", index))
            let url = LibraryLayout.inbox(in: root).appendingPathComponent("\(id.rawValue).png")
            let data = Data("asset-\(index)".utf8)
            try data.write(to: url)
            let asset = AssetRecord(
                id: id,
                relativePath: "Media/Inbox/\(id.rawValue).png",
                displayName: "Screenshot \(index).png",
                kind: .image,
                container: "png",
                createdAt: Date(timeIntervalSince1970: Double(index + 1)),
                importedAt: Date(timeIntervalSince1970: Double(index + 1)),
                byteSize: Int64(data.count),
                contentHash: "hash-\(index)",
                width: 32,
                height: 32,
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

private func waitUntil(
    timeout: Duration = .seconds(5),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for index pipeline state")
}
