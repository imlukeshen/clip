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
    private let clickTracking: EventTrackAssociator

    public init(libraryRoot: URL) async throws {
        let root = libraryRoot.standardizedFileURL
        if let plan = try LibraryMigration.plan(at: root) {
            throw AppRuntimeError.migrationRequired(plan)
        }
        let inboxURL = LibraryLayout.inbox(in: root)
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true
        )
        let bookmarks = BookmarkStore()
        let library = try await LibraryStore(root: root, bookmarks: bookmarks)
        let pipeline = IngestPipeline(library: library, libraryRoot: root)
        let inbox = InboxWatcher(url: inboxURL, bookmarks: bookmarks)
        let pasteboard = PasteboardWatcher()
        let clickTracking = EventTrackAssociator(library: library)

        self.libraryRoot = root
        self.library = library
        self.pipeline = pipeline
        self.clickTracking = clickTracking
        self.coordinator = IngestCoordinator(
            pipeline: pipeline,
            inbox: inbox,
            pasteboard: pasteboard,
            didIngest: { record, sourceURL in
                _ = await clickTracking.associate(record, sourceURL: sourceURL)
            }
        )
    }

    public static func migrate(_ plan: LibraryMigrationPlan, at root: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try LibraryMigration.execute(plan, at: root)
        }.value
    }

    public static func revertMigration(at root: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try LibraryMigration.revert(at: root)
        }.value
    }

    public func start() async throws {
        _ = await clickTracking.start()
        do {
            try await coordinator.start()
        } catch {
            await clickTracking.stop()
            throw error
        }
    }

    public func stop() async {
        await coordinator.stop()
        await clickTracking.stop()
    }

    public func ingest(_ url: URL, source: IngestSource) async throws -> AssetRecord {
        let record = try await pipeline.ingest(url, source: source)
        return await clickTracking.associate(record, sourceURL: url)
    }

    public func assets() async throws -> [AssetRecord] {
        try await library.assets(kind: nil, limit: 500, offset: 0)
    }

    public func url(for assetID: AssetID) async throws -> URL {
        try await library.url(for: assetID)
    }

    public func projectsReferencing(assetIDs: [AssetID]) async throws -> [ProjectSummary] {
        try await library.projectsReferencing(assetIDs: assetIDs)
    }

    public func trash(assetIDs: [AssetID]) async throws -> TrashReceipt {
        try await library.trash(assetIDs: assetIDs)
    }

    public func restore(_ receipt: TrashReceipt) async throws {
        try await library.restore(receipt)
    }

    public func eventTracks(for assetIDs: [AssetID]) async -> [AssetID: EventTrack] {
        var tracks: [AssetID: EventTrack] = [:]
        for assetID in assetIDs {
            if let track = try? await library.eventTrack(for: assetID) {
                tracks[assetID] = track
            }
        }
        return tracks
    }

    public func clickTrackingState() async -> ClickTrackingState {
        await clickTracking.state
    }

    public func startClickTracking() async -> ClickTrackingState {
        await clickTracking.start()
    }

    public func convert(
        _ jobs: [(ConversionPlan, URL, URL)],
        concurrency: Int = 2
    ) async -> AsyncThrowingStream<BatchProgress, Error> {
        await converter.convert(jobs, concurrency: concurrency)
    }

    public func saveProject(_ document: ProjectDocument) async throws {
        try await library.saveProject(document)
    }

    public func appendHistory(_ inverse: GraphPatch, project: ProjectID) async throws {
        try await library.appendHistory(inverse, project: project)
    }

    public func changes() -> AsyncStream<LibraryChange> {
        library.changes
    }

}

public enum AppRuntimeError: Error, Sendable {
    case migrationRequired(LibraryMigrationPlan)
}
