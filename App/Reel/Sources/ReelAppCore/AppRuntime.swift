import CaptureKit
import ConvertKit
import CoreModel
import Foundation
import LibraryStore

/// Owns the long-lived local services used by the application shell.
public actor AppRuntime {
    public let libraryRoot: URL

    private let library: LibraryStore
    private let pipeline: IngestPipeline
    private let coordinator: IngestCoordinator
    private let converter = Converter()

    public init(libraryRoot: URL) async throws {
        let root = libraryRoot.standardizedFileURL
        let inboxURL = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true
        )
        let bookmarks = BookmarkStore()
        let library = try await LibraryStore(root: root, bookmarks: bookmarks)
        let pipeline = IngestPipeline(library: library, libraryRoot: root)
        let inbox = InboxWatcher(url: inboxURL, bookmarks: bookmarks)
        let pasteboard = PasteboardWatcher()

        self.libraryRoot = root
        self.library = library
        self.pipeline = pipeline
        self.coordinator = IngestCoordinator(
            pipeline: pipeline,
            inbox: inbox,
            pasteboard: pasteboard
        )
    }

    public func start() async throws {
        try await coordinator.start()
    }

    public func stop() async {
        await coordinator.stop()
    }

    public func ingest(_ url: URL, source: IngestSource) async throws -> AssetRecord {
        try await pipeline.ingest(url, source: source)
    }

    public func assets() async throws -> [AssetRecord] {
        try await library.assets(kind: nil, limit: 500, offset: 0)
    }

    public func url(for assetID: AssetID) async throws -> URL {
        try await library.url(for: assetID)
    }

    public func convert(
        _ jobs: [(ConversionPlan, URL, URL)],
        concurrency: Int = 2
    ) async -> AsyncThrowingStream<BatchProgress, Error> {
        await converter.convert(jobs, concurrency: concurrency)
    }

    public func changes() -> AsyncStream<LibraryChange> {
        library.changes
    }
}
