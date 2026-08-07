import CaptureKit
import ConvertKit
import CoreModel
import CryptoKit
import Foundation
import LibraryStore
import MediaEngine
import SearchEngine
import TextEngine

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
    private let indexPipeline: IndexPipeline
    private let searchEngine: SearchEngine
    private let coordinator: IngestCoordinator
    private let converter: Converter
    private let clickTracking: EventTrackAssociator
    private let libraryWatcher: LibraryRootWatcher
    private let history: CaptureHistory
    private let scratchTextStore: ScratchTextStore
    private let clipboardWatcher = ClipboardWatcher()
    private var clipboardTask: Task<Void, Never>?
    private var isClipboardCaptureEnabled: Bool
    private var captureDirectory: URL

    private let didCaptureClipboard: @Sendable () async -> Void

    /// - Parameters:
    ///   - didCaptureSystemFile: Called with the file macOS wrote when the user
    ///     takes a screenshot or finishes a recording. The app decides what
    ///     happens to it; the runtime deliberately does not import it.
    ///   - didCaptureClipboard: Called after the system-wide clipboard watcher
    ///     records something the user copied, so the app can refresh the history.
    public init(
        libraryRoot: URL,
        conversionCapabilities: ConversionCapabilities = .appStore,
        isClipboardCaptureEnabled: Bool = false,
        didAutomaticallyIngest: @escaping @Sendable (AssetRecord) async -> Void = { _ in },
        didCaptureSystemFile: @escaping @Sendable (URL) async -> Void = { _ in },
        didCaptureClipboard: @escaping @Sendable () async -> Void = {}
    ) async throws {
        let root = libraryRoot.resolvingSymlinksInPath().standardizedFileURL
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
        let embeddingProvider = NaturalLanguageEmbeddingProvider()
        let indexPipeline = IndexPipeline(
            store: library,
            processor: LocalIndexStageProcessor(
                store: library,
                embeddingProvider: embeddingProvider
            )
        )
        let searchEngine = SearchEngine(
            store: library,
            embeddingProvider: embeddingProvider
        )
        let libraryInboxes = [InboxWatcher(url: inboxURL, bookmarks: bookmarks)]
        let shouldMonitorCaptureDirectory = Self.shouldMonitorCaptureDirectory(
            isUITesting: Self.isUITesting,
            hasExplicitOverride: preferredCaptureDirectory.hasExplicitOverride,
            captureDirectory: captureDirectory,
            inboxDirectory: inboxURL
        )
        let captureInboxes: [InboxWatcher]
        if shouldMonitorCaptureDirectory {
            captureInboxes = [
                InboxWatcher(
                    url: captureDirectory,
                    bookmarks: bookmarks,
                    usesSecurityScope: preferredCaptureDirectory.usesSecurityScope
                )
            ]
        } else {
            captureInboxes = []
        }
        let history = CaptureHistory(
            directory: LibraryLayout.captureHistory(in: root),
            limit: .clipboard
        )
        let clickTracking = EventTrackAssociator(library: library)

        self.didCaptureClipboard = didCaptureClipboard
        self.isClipboardCaptureEnabled = isClipboardCaptureEnabled
        self.converter = Converter(capabilities: conversionCapabilities)
        self.libraryRoot = root
        self.library = library
        self.bookmarks = bookmarks
        self.folders = LibraryFolders(root: root, library: library)
        self.pipeline = pipeline
        self.indexPipeline = indexPipeline
        self.searchEngine = searchEngine
        self.clickTracking = clickTracking
        self.captureDirectory = captureDirectory
        self.libraryWatcher = LibraryRootWatcher(url: LibraryLayout.media(in: root)) {
            Task { await library.refreshLocations() }
        }
        self.history = history
        self.scratchTextStore = ScratchTextStore(directory: LibraryLayout.scratch(in: root))
        self.coordinator = IngestCoordinator(
            pipeline: pipeline,
            libraryInboxes: libraryInboxes,
            captureInboxes: captureInboxes,
            history: history,
            didIngest: { record, sourceURL in
                let associated = await clickTracking.associate(record, sourceURL: sourceURL)
                await indexPipeline.enqueue(
                    associated.id,
                    stages: Self.indexStages(for: associated)
                )
                await didAutomaticallyIngest(associated)
            },
            didCapture: didCaptureSystemFile
        )
    }

    private static func preferredCaptureDirectory(
        saved: URL?
    ) -> (url: URL, usesSecurityScope: Bool, hasExplicitOverride: Bool) {
        #if DEBUG
            if let override = ProcessInfo.processInfo.environment["REEL_CAPTURE_SOURCE"],
                !override.isEmpty
            {
                return (
                    URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL,
                    false,
                    true
                )
            }
        #endif
        if let saved {
            return (saved.standardizedFileURL, true, false)
        }
        return (SystemCaptureDestination.current(), false, false)
    }

    static func shouldMonitorCaptureDirectory(
        isUITesting: Bool,
        hasExplicitOverride: Bool,
        captureDirectory: URL,
        inboxDirectory: URL
    ) -> Bool {
        guard captureDirectory.standardizedFileURL != inboxDirectory.standardizedFileURL else {
            return false
        }
        return !isUITesting || hasExplicitOverride
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
        try await library.requeueStaleOCRJobs(
            currentRevision: VisionTextRecognizer.revision
        )
        let existingAssets = try await library.assets(kind: nil, limit: Int.max, offset: 0)
        for asset in existingAssets {
            await indexPipeline.enqueue(asset.id, stages: Self.indexStages(for: asset))
        }
        await indexPipeline.resumePending()
        libraryWatcher.start()
        _ = await clickTracking.start()
        if isClipboardCaptureEnabled {
            await history.setClipboardRecordingEnabled(true)
            beginClipboardCapture()
        }
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

    /// Starts recording everything the user copies system-wide into the history.
    private func beginClipboardCapture() {
        guard clipboardTask == nil else { return }
        let changes = clipboardWatcher.changes
        clipboardTask = Task { [weak self] in
            await self?.clipboardWatcher.start()
            for await change in changes {
                guard !Task.isCancelled else { return }
                await self?.recordClipboardChange(change)
            }
        }
    }

    /// Enables or disables clipboard observation without affecting the global
    /// panel shortcut. Disabling immediately stops polling and recording.
    public func setClipboardCaptureEnabled(_ isEnabled: Bool) async {
        isClipboardCaptureEnabled = isEnabled
        await history.setClipboardRecordingEnabled(isEnabled)
        if isEnabled {
            beginClipboardCapture()
        } else {
            clipboardTask?.cancel()
            clipboardTask = nil
            await clipboardWatcher.stop()
        }
    }

    private func recordClipboardChange(_ change: ClipboardChange) async {
        guard isClipboardCaptureEnabled, !Task.isCancelled else { return }
        do {
            switch change {
            case .text(let text):
                try await history.recordClipboard(text: text)
            case .image(let data, let pathExtension):
                try await history.recordClipboard(
                    imageData: data,
                    pathExtension: pathExtension,
                    displayName: "Copied image"
                )
            case .fileURLs(let urls):
                try await history.recordClipboard(fileURLs: urls)
            }
            guard isClipboardCaptureEnabled, !Task.isCancelled else { return }
            await didCaptureClipboard()
        } catch {
            // A copy the history cannot store is not worth interrupting for; the
            // original is untouched wherever it lives.
        }
    }

    /// Puts a history entry back on the pasteboard and tells the watcher the
    /// write was app-authored, so paste-back does not re-enter the history.
    public func writeToPasteboard(_ item: CaptureHistoryItem) async {
        let changeCount = CapturePasteboard.write(history.url(for: item), kind: item.kind)
        await clipboardWatcher.markSelfCopy(expected: changeCount)
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
        try await coordinator.addCaptureInbox(watcher)
        captureDirectory = bookmarked
        return CaptureDirectoryStatus(url: bookmarked, isWatching: true)
    }

    /// Recent captures, newest first. Reading also prunes anything expired.
    public func captureHistory() async -> [CaptureHistoryItem] {
        await history.items()
    }

    public nonisolated func captureHistoryURL(for item: CaptureHistoryItem) -> URL {
        history.url(for: item)
    }

    /// Copies a system capture into the history.
    @discardableResult
    public func stageCapture(_ url: URL) async throws -> CaptureHistoryItem {
        try await coordinator.stage(url)
    }

    public func removeCapture(_ id: UUID) async {
        await history.remove(id)
    }

    public func clearCaptureHistory() async {
        await history.clear()
    }

    /// Imports a history entry into the library, leaving the entry in place so
    /// saving twice is not a way to lose it.
    public func saveCaptureToLibrary(_ item: CaptureHistoryItem) async throws -> AssetRecord {
        try await ingest(history.url(for: item), source: .inbox)
    }

    public func stop() async {
        libraryWatcher.stop()
        clipboardTask?.cancel()
        clipboardTask = nil
        await clipboardWatcher.stop()
        await history.setClipboardRecordingEnabled(false)
        await coordinator.stop()
        await clickTracking.stop()
        await indexPipeline.stop()
    }

    public func ingest(_ url: URL, source: IngestSource) async throws -> AssetRecord {
        let record = try await pipeline.ingest(url, source: source)
        let associated = await clickTracking.associate(record, sourceURL: url)
        await indexPipeline.enqueue(associated.id, stages: Self.indexStages(for: associated))
        return associated
    }

    /// Materializes a still as a short movie so the existing timeline graph,
    /// compositor, effects, and exporter can edit it exactly like a video clip.
    public func ingestTimelineImage(
        _ imageURL: URL,
        source: IngestSource
    ) async throws -> AssetRecord {
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipTimelineStill/\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let sourceName = imageURL.deletingPathExtension().lastPathComponent
        let outputURL = stagingRoot.appendingPathComponent("\(sourceName).mov")
        try await StillImageClipBuilder().build(
            imageAt: imageURL,
            outputURL: outputURL
        )
        return try await ingest(outputURL, source: source)
    }

    /// The pasteboard may offer pixels without a file URL. Stage those bytes
    /// only long enough to build the timeline-compatible still clip.
    public func ingestTimelineImageData(
        _ data: Data,
        pathExtension: String,
        source: IngestSource = .pasteboard
    ) async throws -> AssetRecord {
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipTimelinePaste/\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let normalizedExtension = pathExtension.lowercased() == "tiff" ? "tiff" : "png"
        let inputURL = stagingRoot.appendingPathComponent(
            "Pasted Image.\(normalizedExtension)"
        )
        try data.write(to: inputURL, options: .atomic)
        let outputURL = stagingRoot.appendingPathComponent("Pasted Image.mov")
        try await StillImageClipBuilder().build(
            imageAt: inputURL,
            outputURL: outputURL
        )
        return try await ingest(outputURL, source: source)
    }

    public func indexProgress() -> AsyncStream<IndexProgress> {
        indexPipeline.progress
    }

    public func setIndexPauseReasons(_ reasons: Set<IndexPauseReason>) async {
        await indexPipeline.setPauseReasons(reasons)
    }

    public func search(_ query: SearchQuery) async throws -> SearchResponse {
        try await searchEngine.search(query)
    }

    public func searchWithin(_ assetID: AssetID, text: String) async throws -> [SearchMoment] {
        try await searchEngine.searchWithin(assetID, text: text)
    }

    public func indexedText(at time: RationalTime, in assetID: AssetID) async throws -> [OCRSpan] {
        try await searchEngine.textAt(assetID, time: time)
    }

    public func similarAssets(to assetID: AssetID, limit: Int = 20) async throws -> [SearchHit] {
        try await searchEngine.similar(to: assetID, limit: limit)
    }

    public func embeddingModelStatus() async -> EmbeddingIndexStatus {
        await searchEngine.embeddingModelStatus()
    }

    public func rebuildSemanticIndex() async throws {
        try await library.rebuildIndexJobs(scope: .all, stages: [.embedding])
        await indexPipeline.resumePending()
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

    public func renameAsset(_ id: AssetID, to name: String) async throws -> AssetRecord {
        let renamed = try await folders.renameAsset(id, to: name)
        // Keyword search follows the asset table's FTS update trigger. Semantic
        // chunks also include the display name, so replace the completed
        // embedding job rather than using the idempotent ingest-time enqueue.
        await indexPipeline.reindex(renamed.id, stages: [.embedding])
        return renamed
    }

    public func folderDestinations() async throws -> [String] {
        try await folders.destinations()
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
        for item in receipt.items {
            await indexPipeline.enqueue(
                item.asset.id,
                stages: Self.indexStages(for: item.asset)
            )
        }
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
        _ jobs: [BatchConversionJob],
        concurrency: Int = Converter.defaultConcurrency
    ) async -> AsyncThrowingStream<BatchProgress, Error> {
        await converter.convert(jobs, concurrency: concurrency)
    }

    public func cancelConversion(_ id: UUID) async {
        await converter.cancel(jobID: id)
    }

    public func cancelAllConversions() async {
        await converter.cancelAll()
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

    public func textDocument(for assetID: AssetID) throws -> TextDocument? {
        let url = textDocumentURL(for: assetID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TextDocument.self, from: Data(contentsOf: url))
    }

    public func saveTextDocument(_ document: TextDocument, for assetID: AssetID) throws {
        let directory = LibraryLayout.textDocuments(in: libraryRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        try data.write(to: textDocumentURL(for: assetID), options: .atomic)
    }

    public func texProjectDocument(for relativeFolder: String) throws -> TextDocument? {
        let url = texProjectDocumentURL(for: relativeFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TextDocument.self, from: Data(contentsOf: url))
    }

    public func saveTeXProjectDocument(
        _ document: TextDocument,
        for relativeFolder: String
    ) throws {
        let directory = LibraryLayout.texProjects(in: libraryRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        try data.write(to: texProjectDocumentURL(for: relativeFolder), options: .atomic)
    }

    /// Reads a text asset's bytes into an editable buffer, detecting its encoding
    /// and line endings so a later save can reproduce the original file.
    public func loadTextContents(for assetID: AssetID) async throws -> LoadedTextFile {
        let url = try await library.url(for: assetID)
        return try TextFileLoader.load(from: url)
    }

    /// Persists an edited text asset's bytes in place — the writable-text
    /// exception to invariant I5 (ADR-0009). The caller supplies the content
    /// hash so hashing stays in the App layer, matching ingest.
    public func saveTextContents(
        _ data: Data,
        for assetID: AssetID,
        contentHash: String
    ) async throws {
        _ = try await library.saveTextContents(data, for: assetID, contentHash: contentHash)
        await indexPipeline.reindex(assetID, stages: [.text, .embedding])
    }

    /// Lists persisted scratch buffers without loading their full contents.
    public func scratchTextRecords() async throws -> [ScratchTextRecord] {
        try await scratchTextStore.records()
    }

    /// Creates and immediately persists a new empty scratch buffer.
    public func createScratchTextBuffer() async throws -> ScratchTextBuffer {
        try await scratchTextStore.create()
    }

    /// Restores a scratch buffer when both its structure and contents still exist.
    public func scratchTextBuffer(_ id: DocumentID) async throws -> ScratchTextBuffer? {
        try await scratchTextStore.load(id)
    }

    /// Persists the structural half of a scratch buffer.
    public func saveScratchTextDocument(_ document: TextDocument) async throws {
        try await scratchTextStore.save(document: document)
    }

    /// Persists the editable content half of a scratch buffer.
    public func saveScratchTextContents(_ data: Data, for id: DocumentID) async throws {
        try await scratchTextStore.save(contents: data, for: id)
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

    private func textDocumentURL(for assetID: AssetID) -> URL {
        LibraryLayout.textDocuments(in: libraryRoot)
            .appendingPathComponent("\(assetID.rawValue).reeltext")
    }

    private func texProjectDocumentURL(for relativeFolder: String) -> URL {
        let digest = SHA256.hash(data: Data(relativeFolder.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return LibraryLayout.texProjects(in: libraryRoot)
            .appendingPathComponent("\(digest).reeltext")
    }

    private static func indexStages(for asset: AssetRecord) -> Set<IndexStage> {
        switch asset.kind {
        case .image: [.metadata, .ocr, .embedding]
        case .video: [.metadata, .ocr, .transcript, .embedding]
        case .audio: [.metadata, .transcript, .embedding]
        case .document: [.metadata, .embedding]
        case .text: [.metadata, .text, .embedding]
        }
    }
}

public enum AppRuntimeError: Error, Sendable {
    case migrationRequired(LibraryMigrationPlan)
}
