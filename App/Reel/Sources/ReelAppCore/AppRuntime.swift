import CaptureKit
import ConvertKit
import CoreModel
import Foundation
import LibraryStore

public struct CaptureDirectoryStatus: Sendable, Equatable {
    public var url: URL
    public var isWatching: Bool

    public init(url: URL, isWatching: Bool) {
        self.url = url
        self.isWatching = isWatching
    }
}

/// Owns the long-lived local services used by the application shell.
public actor AppRuntime {
    public let libraryRoot: URL

    private static let captureBookmarkKey = "capture-directory"

    private let library: LibraryStore
    private let bookmarks: BookmarkStore
    private let folders: LibraryFolders
    private let pipeline: IngestPipeline
    private let coordinator: IngestCoordinator
    private let converter = Converter()
    private let clickTracking: EventTrackAssociator
    private let libraryWatcher: LibraryRootWatcher
    private var captureDirectory: URL

    public init(
        libraryRoot: URL,
        didAutomaticallyIngest: @escaping @Sendable (AssetRecord) async -> Void = { _ in }
    ) async throws {
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
        let savedCaptureDirectory = try? await bookmarks.resolve(key: Self.captureBookmarkKey)
        let preferredCaptureDirectory = Self.preferredCaptureDirectory(
            saved: savedCaptureDirectory
        )
        let captureDirectory = preferredCaptureDirectory.url
        let library = try await LibraryStore(root: root, bookmarks: bookmarks)
        let pipeline = IngestPipeline(library: library, libraryRoot: root)
        let captureDirectories = Self.captureDirectories(
            libraryInbox: inboxURL,
            captureDirectory: captureDirectory,
            captureUsesSecurityScope: preferredCaptureDirectory.usesSecurityScope,
            includesSystemCaptureDirectory: !Self.isUITesting
        )
        let inboxes = captureDirectories.map {
            InboxWatcher(
                url: $0.url,
                bookmarks: bookmarks,
                usesSecurityScope: $0.usesSecurityScope
            )
        }
        let pasteboard = PasteboardWatcher()
        let clickTracking = EventTrackAssociator(library: library)

        self.libraryRoot = root
        self.library = library
        self.bookmarks = bookmarks
        self.folders = LibraryFolders(root: root, library: library)
        self.pipeline = pipeline
        self.clickTracking = clickTracking
        self.captureDirectory = captureDirectory
        self.libraryWatcher = LibraryRootWatcher(url: LibraryLayout.media(in: root)) {
            Task { await library.refreshLocations() }
        }
        self.coordinator = IngestCoordinator(
            pipeline: pipeline,
            inboxes: inboxes,
            pasteboard: pasteboard,
            didIngest: { record, sourceURL in
                let associated = await clickTracking.associate(record, sourceURL: sourceURL)
                await didAutomaticallyIngest(associated)
            }
        )
    }

    private static func preferredCaptureDirectory(
        saved: URL?
    ) -> (url: URL, usesSecurityScope: Bool) {
        #if DEBUG
            if let override = ProcessInfo.processInfo.environment["REEL_CAPTURE_SOURCE"],
                !override.isEmpty
            {
                return (
                    URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL,
                    false
                )
            }
        #endif
        if let saved {
            return (saved.standardizedFileURL, true)
        }
        return (SystemCaptureDestination.current(), false)
    }

    private static func captureDirectories(
        libraryInbox: URL,
        captureDirectory: URL,
        captureUsesSecurityScope: Bool,
        includesSystemCaptureDirectory: Bool
    ) -> [(url: URL, usesSecurityScope: Bool)] {
        var seen: Set<String> = []
        var directories = [(libraryInbox, false)]
        if includesSystemCaptureDirectory {
            directories.append((captureDirectory, captureUsesSecurityScope))
        }
        return directories.compactMap { directory, usesSecurityScope in
            let standardized = directory.standardizedFileURL
            return seen.insert(standardized.path).inserted
                ? (standardized, usesSecurityScope) : nil
        }
    }

    private static var isUITesting: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["CLIP_UI_TESTING"] == "1"
        #else
            false
        #endif
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

    public func start() async throws -> CaptureDirectoryStatus {
        await library.refreshLocations()
        libraryWatcher.start()
        _ = await clickTracking.start()
        do {
            let activeDirectories = try await coordinator.start()
            return CaptureDirectoryStatus(
                url: captureDirectory,
                isWatching: activeDirectories.contains(captureDirectory)
            )
        } catch {
            await clickTracking.stop()
            throw error
        }
    }

    public func grantCaptureDirectoryAccess(_ url: URL) async throws -> CaptureDirectoryStatus {
        let standardized = url.standardizedFileURL
        try await bookmarks.store(standardized, key: Self.captureBookmarkKey)
        let bookmarked = try await bookmarks.resolve(key: Self.captureBookmarkKey)
        let watcher = InboxWatcher(
            url: bookmarked,
            bookmarks: bookmarks,
            usesSecurityScope: true
        )
        try await coordinator.addInbox(watcher)
        captureDirectory = bookmarked
        return CaptureDirectoryStatus(url: bookmarked, isWatching: true)
    }

    public func stop() async {
        libraryWatcher.stop()
        await coordinator.stop()
        await clickTracking.stop()
    }

    public func ingest(_ url: URL, source: IngestSource) async throws -> AssetRecord {
        let record = try await pipeline.ingest(url, source: source)
        return await clickTracking.associate(record, sourceURL: url)
    }

    public func assets() async throws -> [AssetRecord] {
        try await library.assets(kind: nil, limit: Int.max, offset: 0)
    }

    public func folderTree(expanding: Set<String>) async throws -> FolderNode {
        try await folders.tree(expanding: expanding)
    }

    public func createFolder(named name: String, in parent: String) async throws -> String {
        try await folders.createFolder(named: name, in: parent)
    }

    public func renameFolder(_ path: String, to name: String) async throws -> String {
        try await folders.rename(path, to: name)
    }

    public func moveAssets(_ ids: [AssetID], to folder: String) async throws -> [AssetRecord] {
        try await folders.move(ids, to: folder)
    }

    public func moveFolder(_ path: String, to parent: String) async throws -> String {
        try await folders.moveFolder(path, to: parent)
    }

    public func trashFolder(_ path: String) async throws -> FolderTrashReceipt {
        try await folders.trashFolder(path)
    }

    public func restoreFolder(_ receipt: FolderTrashReceipt) async throws {
        try await folders.restoreFolder(receipt)
    }

    public func revealInFinder(_ ids: [AssetID]) async {
        await folders.revealInFinder(ids)
    }

    public func url(for assetID: AssetID) async throws -> URL {
        try await library.url(for: assetID)
    }

    public func urls(for assetIDs: [AssetID]) async -> [URL] {
        var urls: [URL] = []
        for id in assetIDs {
            if let url = try? await library.url(for: id) { urls.append(url) }
        }
        return urls
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

    public func locate(assetID: AssetID, at url: URL) async throws {
        guard let record = try await library.asset(id: assetID) else {
            throw LibraryError.assetNotFound(assetID)
        }
        guard try SampledFileHasher.hash(url) == record.contentHash else {
            throw LibraryError.fileOperationFailed("located file hash does not match")
        }
        try await library.relink(assetID: assetID, to: url)
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

    public func imageDocument(for assetID: AssetID) throws -> ImageDocument? {
        let url = imageDocumentURL(for: assetID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ImageDocument.self, from: Data(contentsOf: url))
    }

    public func saveImageDocument(_ document: ImageDocument) throws {
        let directory = LibraryLayout.imageDocuments(in: libraryRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        try data.write(to: imageDocumentURL(for: document.sourceAssetID), options: .atomic)
    }

    public func pdfDocument(for assetID: AssetID) throws -> PDFEditDocument? {
        let url = pdfDocumentURL(for: assetID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PDFEditDocument.self, from: Data(contentsOf: url))
    }

    public func savePDFDocument(_ document: PDFEditDocument) throws {
        let directory = LibraryLayout.pdfDocuments(in: libraryRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        try data.write(to: pdfDocumentURL(for: document.sourceAssetID), options: .atomic)
    }

    public func changes() -> AsyncStream<LibraryChange> {
        library.changes
    }

    private func imageDocumentURL(for assetID: AssetID) -> URL {
        LibraryLayout.imageDocuments(in: libraryRoot)
            .appendingPathComponent("\(assetID.rawValue).reelimage")
    }

    private func pdfDocumentURL(for assetID: AssetID) -> URL {
        LibraryLayout.pdfDocuments(in: libraryRoot)
            .appendingPathComponent("\(assetID.rawValue).reelpdf")
    }
}

public enum AppRuntimeError: Error, Sendable {
    case migrationRequired(LibraryMigrationPlan)
}
