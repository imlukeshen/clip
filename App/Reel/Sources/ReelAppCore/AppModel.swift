import AIKit
import AppKit
import CaptureKit
import ConvertKit
import CoreModel
import DesignSystem
import Foundation
import LibraryStore
import Observation
import PDFEngine
import SearchEngine
import TextEngine
import UniformTypeIdentifiers

enum SystemCaptureRoute: Sendable, Equatable {
    case timeline
    case history
    case ignore
}

enum SystemCaptureRouting {
    static func route(
        kind: CaptureHistoryItem.Kind,
        destination: CaptureDestination,
        hasTimelineEditor: Bool,
        hasBlockingEditor: Bool
    ) -> SystemCaptureRoute {
        guard kind == .video else { return .history }
        if hasTimelineEditor { return .timeline }
        if hasBlockingEditor {
            return destination == .file ? .ignore : .history
        }
        switch destination {
        case .timeline: return .timeline
        case .clipboard: return .history
        case .file: return .ignore
        }
    }
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var selectedWorkspace: Workspace = .inbox
    public var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            scheduleLibrarySearch()
        }
    }
    public private(set) var searchFocusRequest = 0
    public private(set) var searchHits: [SearchHit] = []
    public private(set) var isSearchLoading = false
    public private(set) var isSearchComplete = true
    public private(set) var embeddingModelNeedsReindex = false
    public private(set) var assets: [AssetRecord] = []
    /// Stable IDs currently undergoing a filesystem rename.
    public private(set) var renamingAssetIDs: Set<AssetID> = []
    public private(set) var folderTree: FolderNode?
    public private(set) var folderDestinations: [String] = ["", "Inbox"]
    public private(set) var expandedFolders: Set<String>
    public var selectedFolderPath: String? = "Inbox"
    public var browserViewMode: BrowserViewMode = .grid
    public var assetSort: AssetSort = .modified
    public var isInspectorVisible = true
    public private(set) var inspectorWidth = InspectorLayout.defaultWidth
    public var appearance: AppearancePreference {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: "reel.appearance")
        }
    }
    public var isCommandPalettePresented = false
    public var commandQuery = ""
    public private(set) var shortcutRow: ShortcutRowModel
    public private(set) var libraryRoot: URL
    public private(set) var isWatching = false
    public private(set) var ingestCount = 0
    public private(set) var indexProgress = IndexProgress()
    public private(set) var conversionQueue: [ConversionQueueItem] = []
    public private(set) var conversionConcurrency: Int
    public private(set) var conversionDestinationFolder: URL
    public private(set) var conversionDestination: ExportDestination
    public private(set) var conversionConflictPolicy: ConversionConflictPolicy
    public private(set) var conversionAggregateProgress = 0.0
    public private(set) var conversionCompletedCount = 0
    public private(set) var conversionBatchTotal = 0
    public private(set) var editor: EditorViewModel?
    public private(set) var imageEditor: ImageEditorViewModel?
    public private(set) var pdfEditor: PDFEditorViewModel?
    public private(set) var textEditor: TextEditorViewModel?
    /// Scratch buffers available for restoration in the text workspace.
    public private(set) var scratchBuffers: [ScratchTextRecord] = []
    public private(set) var lastMessage: String?
    public private(set) var clickTrackingState: ClickTrackingState = .checking
    public private(set) var captureDirectory = SystemCaptureDestination.current()
    public private(set) var isCaptureDirectoryWatched = false
    public private(set) var captureHistory: [CaptureHistoryItem] = []
    public private(set) var isAddingTimelineMedia = false
    public var isCaptureHistoryPresented = false
    /// Whether Clip owns the system-wide Command-Shift-C shortcut. This stays
    /// separate from clipboard capture so users can keep Maccy or another
    /// clipboard manager on that key combination without disabling Clip's
    /// history itself.
    public var isGlobalClipboardShortcutEnabled: Bool {
        didSet {
            guard isGlobalClipboardShortcutEnabled != oldValue else { return }
            UserDefaults.standard.set(
                isGlobalClipboardShortcutEnabled,
                forKey: Self.globalClipboardShortcutPreferenceKey
            )
        }
    }
    /// Allows Clip to fetch only pinned, hash-verified open fonts when a PDF's
    /// embedded subset cannot represent newly typed characters.
    public var isPDFFontAutoDownloadEnabled: Bool {
        didSet {
            guard isPDFFontAutoDownloadEnabled != oldValue else { return }
            UserDefaults.standard.set(
                isPDFFontAutoDownloadEnabled,
                forKey: Self.pdfFontAutoDownloadPreferenceKey
            )
            pdfEditor?.automaticallyResolveMissingFonts = isPDFFontAutoDownloadEnabled
        }
    }
    /// Where a finished recording goes when no editor is open to take it.
    public private(set) var captureDestination = CaptureDestination.restored()
    public let selection = SelectionModel()
    public let undoManager = UndoManager()
    public private(set) var pendingTrashConfirmation: TrashConfirmation?
    public private(set) var pendingMigrationPlan: LibraryMigrationPlan?
    public private(set) var canRevertMigration = false
    public var assistantDraft = ""
    public private(set) var assistantMessages: [AssistantMessage] = []
    public private(set) var pendingAssistantActions: [PendingAssistantAction] = []
    public private(set) var isAssistantWorking = false
    public let aiSettings: AISettingsModel
    public let conversionCapabilities: ConversionCapabilities

    /// The inspectable package cache used by the bundled LaTeX engine.
    public var texPackageCacheURL: URL {
        LibraryLayout.texCache(in: libraryRoot)
    }

    public var pdfFontCacheURL: URL {
        LibraryLayout.pdfFontCache(in: libraryRoot)
    }

    private let shortcutReader: ShortcutReader
    private var runtime: AppRuntime?
    private var libraryChangesTask: Task<Void, Never>?
    private var indexProgressTask: Task<Void, Never>?
    private var indexActivityTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var assetRefreshGeneration = 0
    private var conversionTask: Task<Void, Never>?
    private var hasStarted = false
    private var folderBackHistory: [String?] = []
    private var folderForwardHistory: [String?] = []

    private static let globalClipboardShortcutPreferenceKey =
        "clip.globalClipboardShortcutEnabled"
    private static let pdfFontAutoDownloadPreferenceKey =
        "clip.pdf.autoResolveFonts"

    public init(
        libraryRoot: URL = AppModel.defaultLibraryRoot,
        shortcutReader: ShortcutReader = ShortcutReader(),
        conversionCapabilities: ConversionCapabilities = .appStore
    ) {
        let normalizedLibraryRoot = libraryRoot.standardizedFileURL
        self.libraryRoot = normalizedLibraryRoot
        self.shortcutReader = shortcutReader
        self.conversionCapabilities = conversionCapabilities
        self.shortcutRow = ShortcutRowModel(result: shortcutReader.read())
        self.aiSettings = AISettingsModel(libraryRoot: normalizedLibraryRoot)
        self.conversionConcurrency = min(
            8,
            max(
                1,
                UserDefaults.standard.object(forKey: "clip.convert.concurrency") as? Int
                    ?? Converter.defaultConcurrency
            )
        )
        self.conversionDestinationFolder =
            UserDefaults.standard.string(
                forKey: "clip.convert.destinationFolder"
            ).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? normalizedLibraryRoot
        self.conversionDestination =
            UserDefaults.standard.data(forKey: "clip.convert.destination")
            .flatMap { try? JSONDecoder().decode(ExportDestination.self, from: $0) }
            ?? ExportDestination(
                bookmarkKey: "conversion",
                subpathTemplate: "Exports/{date}",
                filenameTemplate: "{project}-{preset}-{index}",
                onCompletion: .reveal
            )
        self.conversionConflictPolicy =
            UserDefaults.standard.string(forKey: "clip.convert.conflictPolicy")
            .flatMap(ConversionConflictPolicy.init(rawValue:)) ?? .rename
        self.expandedFolders = Set(
            UserDefaults.standard.stringArray(forKey: "reel.expandedFolders") ?? [""]
        )
        self.appearance =
            UserDefaults.standard.string(forKey: "reel.appearance")
            .flatMap(AppearancePreference.init(rawValue:)) ?? .system
        self.isGlobalClipboardShortcutEnabled =
            UserDefaults.standard.object(forKey: Self.globalClipboardShortcutPreferenceKey)
            as? Bool ?? true
        self.isPDFFontAutoDownloadEnabled =
            UserDefaults.standard.object(forKey: Self.pdfFontAutoDownloadPreferenceKey)
            as? Bool ?? true
        self.inspectorWidth = InspectorLayout.restoredWidth()
        self.undoManager.groupsByEvent = false
    }

    public var selectedAssetID: String? {
        get { selection.anchor?.rawValue }
        set {
            guard let newValue else {
                selection.deselectAll()
                return
            }
            let id = AssetID(rawValue: newValue)
            selection.click(id)
        }
    }

    public static var defaultLibraryRoot: URL {
        let movies =
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return preferredAppDirectory(in: movies)
    }

    public static var sandboxLibraryRoot: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return preferredAppDirectory(in: support)
    }

    static func preferredAppDirectory(in parent: URL) -> URL {
        let current = parent.appendingPathComponent("Clip", isDirectory: true)
        let legacy = parent.appendingPathComponent("Reel", isDirectory: true)
        if FileManager.default.fileExists(atPath: current.path)
            || !FileManager.default.fileExists(atPath: legacy.path)
        {
            return current
        }
        return legacy
    }

    public var visibleAssets: [AssetRecord] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, !isSearchLoading || !searchHits.isEmpty {
            let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            return searchHits.compactMap { assetsByID[$0.assetID] }
        }
        let scoped: [AssetRecord]
        if !query.isEmpty {
            scoped = assets
        } else if selectedWorkspace == .inbox, let selectedFolderPath {
            let prefix =
                selectedFolderPath.isEmpty
                ? "Media/" : "Media/\(selectedFolderPath)/"
            scoped = assets.filter { asset in
                guard asset.relativePath.hasPrefix(prefix) else { return false }
                return !asset.relativePath.dropFirst(prefix.count).contains("/")
            }
        } else {
            scoped = assets
        }
        let searched =
            query.isEmpty ? scoped : scoped.filter { BrowserSearch.matches($0, query: query) }
        return searched.sorted(by: assetOrdering)
    }

    public var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var matchingFolders: [FolderNode] {
        BrowserSearch.matchingFolders(in: folderTree, query: searchQuery)
    }

    public var searchResultDescription: String {
        let mediaCount = isSearching ? searchHits.count : visibleAssets.count
        let folderCount = matchingFolders.count
        return
            "\(mediaCount) media item\(mediaCount == 1 ? "" : "s") and \(folderCount) folder\(folderCount == 1 ? "" : "s")"
    }

    public var currentFolderName: String {
        selectedFolderPath?.split(separator: "/").last.map(String.init) ?? "Recent"
    }

    public var canNavigateBack: Bool { !folderBackHistory.isEmpty }
    public var canNavigateForward: Bool { !folderForwardHistory.isEmpty }

    public func assetCount(for workspace: Workspace) -> Int {
        switch workspace {
        case .inbox: assets.count
        case .video: assets.count(where: { $0.kind == .video })
        case .photo: assets.count(where: { $0.kind == .image })
        case .pdf: assets.count(where: { $0.kind == .document })
        case .text: assets.count(where: { $0.kind == .text })
        case .convert: conversionQueue.count
        }
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        refreshShortcuts()
        do {
            let runtime = try await AppRuntime(
                libraryRoot: libraryRoot,
                conversionCapabilities: conversionCapabilities,
                didAutomaticallyIngest: { [weak self] record in
                    await self?.handleAutomaticIngest(record)
                },
                didCaptureSystemFile: { [weak self] url in
                    await self?.handleSystemCapture(url)
                },
                didCaptureClipboard: { [weak self] in
                    await self?.refreshCaptureHistory()
                }
            )
            self.runtime = runtime
            beginIndexMonitoring(runtime)
            scheduleLibrarySearch()
            let changes = await runtime.changes()
            libraryChangesTask = Task { [weak self] in
                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    await self?.refreshAssets()
                }
            }
            let captureStatus = try await runtime.start()
            isWatching = true
            captureDirectory = captureStatus.url
            isCaptureDirectoryWatched = captureStatus.isWatching
            canRevertMigration = LibraryMigration.canRevert(at: libraryRoot)
            clickTrackingState = await runtime.clickTrackingState()
            embeddingModelNeedsReindex = await runtime.embeddingModelStatus().needsReindex
            await refreshAssets()
            await refreshScratchBuffers()
            await refreshCaptureHistory()
        } catch AppRuntimeError.migrationRequired(let plan) {
            isWatching = false
            pendingMigrationPlan = plan
        } catch {
            isWatching = false
            lastMessage = "The library could not be opened. Check the folder and try again."
        }
    }

    private func beginIndexMonitoring(_ runtime: AppRuntime) {
        indexProgressTask?.cancel()
        indexActivityTask?.cancel()
        indexProgressTask = Task { [weak self] in
            let updates = await runtime.indexProgress()
            for await progress in updates {
                guard !Task.isCancelled else { return }
                let wasComplete = self?.indexProgress.isComplete ?? true
                self?.indexProgress = progress
                if !wasComplete, progress.isComplete, self?.isSearching == true {
                    self?.scheduleLibrarySearch()
                }
            }
        }
        indexActivityTask = Task { [weak self] in
            var previous: Set<IndexPauseReason>?
            while !Task.isCancelled {
                guard let self else { return }
                var reasons: Set<IndexPauseReason> = []
                if editor?.isPlaying == true { reasons.insert(.playback) }
                if editor?.isExporting == true { reasons.insert(.export) }
                if isConverting { reasons.insert(.conversion) }
                if reasons != previous {
                    await runtime.setIndexPauseReasons(reasons)
                    previous = reasons
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func scheduleLibrarySearch() {
        searchTask?.cancel()
        let value = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            searchHits = []
            isSearchLoading = false
            isSearchComplete = true
            return
        }
        guard let runtime else {
            isSearchLoading = true
            return
        }
        isSearchLoading = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(160))
                let response = try await runtime.search(SearchQuery(text: value, limit: 100))
                guard !Task.isCancelled,
                    self?.searchQuery.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) == value
                else { return }
                self?.searchHits = response.hits
                self?.isSearchComplete = response.isComplete
                self?.isSearchLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchHits = []
                self?.isSearchComplete = true
                self?.isSearchLoading = false
                self?.lastMessage = error.localizedDescription
            }
        }
    }

    public func showWorkspace(_ workspace: Workspace) {
        let workspaceChanged = selectedWorkspace != workspace
        closeOpenEditors()
        selectedWorkspace = workspace
        if workspace == .convert {
            clearSearch()
        }
        if workspaceChanged {
            selection.deselectAll()
        }
    }

    /// Makes the palette's “Open Video Editor” command literal: it focuses an
    /// existing timeline or creates an empty project that is immediately ready
    /// for pasted and dropped media.
    public func openVideoEditorFromCommandPalette() {
        if editor != nil {
            selectedWorkspace = .video
            return
        }
        closeImageEditor()
        closePDFEditor()
        closeTextEditor()
        guard imageEditor == nil, pdfEditor == nil, textEditor == nil else {
            lastMessage = "Resolve the open document before switching to video editing."
            return
        }
        createEmptyVideoEditor()
    }

    /// Decides what happens to a file macOS just wrote for a screenshot or
    /// recording.
    ///
    /// A recording lands in the timeline if one is open, because that is what
    /// you were about to do with it anyway. Everything else is staged in the
    /// history, where it expires — the library only gains an asset when you
    /// explicitly save one.
    private func handleSystemCapture(_ url: URL) async {
        guard let runtime else { return }
        guard let kind = CaptureHistoryItem.kind(forPathExtension: url.pathExtension) else {
            return
        }
        let route = SystemCaptureRouting.route(
            kind: kind,
            destination: captureDestination,
            hasTimelineEditor: editor != nil,
            hasBlockingEditor: imageEditor != nil || pdfEditor != nil || textEditor != nil
        )
        switch route {
        case .timeline:
            do {
                let record = try await runtime.ingest(url, source: .inbox)
                await refreshAssets()
                await handleAutomaticIngest(record)
            } catch {
                lastMessage = "That recording could not be opened in the timeline."
            }
        case .history:
            do {
                let item = try await runtime.stageCapture(url)
                await runtime.writeToPasteboard(item)
                await refreshCaptureHistory()
                lastMessage =
                    kind == .video
                    ? "Recording added to Clip Clipboard."
                    : "Screenshot added to Clip Clipboard."
            } catch {
                // A format the history cannot hold is not worth interrupting for;
                // the file is still exactly where the system put it.
            }
        case .ignore:
            break
        }
    }

    public func refreshCaptureHistory() async {
        guard let runtime else { return }
        captureHistory = await runtime.captureHistory()
    }

    public func captureHistoryURL(for item: CaptureHistoryItem) -> URL? {
        runtime?.captureHistoryURL(for: item)
    }

    public func setCaptureDestination(_ destination: CaptureDestination) {
        guard destination != captureDestination else { return }
        captureDestination = destination
        destination.store()
    }

    public func setGlobalClipboardShortcutEnabled(_ isEnabled: Bool) {
        isGlobalClipboardShortcutEnabled = isEnabled
    }

    public func setPDFFontAutoDownloadEnabled(_ isEnabled: Bool) {
        isPDFFontAutoDownloadEnabled = isEnabled
    }

    /// Reads the richest media representation from the system pasteboard and
    /// adds it to the open timeline. Finder file copies stay file-backed;
    /// raw screenshot pixels are accepted as a still clip as well.
    public func pasteMediaIntoTimeline() {
        guard editor != nil else {
            lastMessage = "Open the video editor before pasting media."
            return
        }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            addMediaToOpenTimeline(urls, source: .pasteboard)
            return
        }
        if let data = pasteboard.data(forType: .png) {
            addImageDataToOpenTimeline(data, pathExtension: "png")
            return
        }
        if let data = pasteboard.data(forType: .tiff) {
            addImageDataToOpenTimeline(data, pathExtension: "tiff")
            return
        }
        lastMessage = "Copy a video, photo, or audio file, then paste it into the timeline."
    }

    /// Adds the richest image representation on the system pasteboard to the
    /// open photo document as a durable, independently editable layer.
    public func pasteImageIntoCanvas() {
        guard let imageEditor else {
            lastMessage = "Open a photo before pasting an image."
            return
        }

        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            let imageURLs = urls.filter(Self.isImageURL)
            if !imageURLs.isEmpty {
                let inserted = imageURLs.reduce(into: 0) { count, url in
                    if (try? imageEditor.addRasterLayer(from: url)) != nil { count += 1 }
                }
                if inserted > 0 {
                    lastMessage =
                        inserted == 1
                        ? "Pasted image as a new layer."
                        : "Pasted \(inserted) images as new layers."
                    return
                }
            }
        }

        if let data = pasteboard.data(forType: .png) {
            do {
                try imageEditor.addRasterLayer(data: data, suggestedName: "Pasted Image.png")
                lastMessage = "Pasted image as a new layer."
            } catch {
                lastMessage = "The pasted image could not be added to the canvas."
            }
            return
        }
        if let data = pasteboard.data(forType: .tiff) {
            do {
                try imageEditor.addRasterLayer(data: data, suggestedName: "Pasted Image.tiff")
                lastMessage = "Pasted image as a new layer."
            } catch {
                lastMessage = "The pasted image could not be added to the canvas."
            }
            return
        }

        lastMessage = "Copy an image or image file, then paste it onto the canvas."
    }

    public func addMediaToOpenTimeline(_ urls: [URL], source: IngestSource) {
        guard !urls.isEmpty, !isAddingTimelineMedia, let activeEditor = editor,
            let runtime
        else { return }
        isAddingTimelineMedia = true
        Task {
            defer { isAddingTimelineMedia = false }
            var insertedCount = 0
            var failedFileName: String?
            for url in urls {
                let didStartSecurityScope =
                    (source == .picker || source == .pasteboard)
                    && url.startAccessingSecurityScopedResource()
                defer {
                    if didStartSecurityScope { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let record: AssetRecord
                    if Self.isImageURL(url) {
                        record = try await runtime.ingestTimelineImage(url, source: source)
                    } else if Self.isVideoURL(url) || Self.isAudioURL(url) {
                        record = try await runtime.ingest(url, source: source)
                    } else {
                        continue
                    }
                    await refreshAssets()
                    guard editor === activeEditor else { return }
                    if activeEditor.insert(record) { insertedCount += 1 }
                } catch {
                    failedFileName = url.lastPathComponent
                }
            }
            if insertedCount > 0 {
                lastMessage =
                    insertedCount == 1
                    ? "Added media to the timeline."
                    : "Added \(insertedCount) items to the timeline."
            } else if let failedFileName {
                lastMessage = "Couldn't add \(failedFileName) to the timeline."
            } else {
                lastMessage = "Paste or drop video, photos, or audio into the timeline."
            }
        }
    }

    private func addImageDataToOpenTimeline(_ data: Data, pathExtension: String) {
        guard !isAddingTimelineMedia, let activeEditor = editor, let runtime else { return }
        isAddingTimelineMedia = true
        Task {
            defer { isAddingTimelineMedia = false }
            do {
                let record = try await runtime.ingestTimelineImageData(
                    data,
                    pathExtension: pathExtension
                )
                await refreshAssets()
                guard editor === activeEditor else { return }
                if activeEditor.insert(record) {
                    lastMessage = "Added the pasted image as a three-second clip."
                }
            } catch {
                lastMessage = "The pasted image could not be added to the timeline."
            }
        }
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true
            || ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp"].contains(pathExtension)
    }

    private static func isVideoURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return UTType(filenameExtension: pathExtension)?.conforms(to: .movie) == true
            || ["mov", "mp4", "m4v", "webm", "mkv"].contains(pathExtension)
    }

    private static func isAudioURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return UTType(filenameExtension: pathExtension)?.conforms(to: .audio) == true
            || ["wav", "aif", "aiff", "m4a", "mp3", "aac", "flac"].contains(pathExtension)
    }

    /// Restores an entry to the system pasteboard, then runs `completion` only
    /// after the pasteboard write and watcher bookkeeping have both finished.
    /// The floating clipboard uses that ordering to send Paste without racing
    /// the asynchronous history store.
    public func copyCaptureToPasteboard(
        _ item: CaptureHistoryItem,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard let runtime else {
            lastMessage = "The clipboard is still opening. Try again in a moment."
            return
        }
        Task {
            await runtime.writeToPasteboard(item)
            lastMessage = "Restored \(item.displayName) to the clipboard."
            completion()
        }
    }

    public func reportAutomaticPasteUnavailable() {
        lastMessage =
            "Copied the item. Enable Accessibility access for one-click paste into other apps."
    }

    public func saveCaptureToLibrary(_ item: CaptureHistoryItem) {
        guard let runtime else { return }
        Task {
            do {
                _ = try await runtime.saveCaptureToLibrary(item)
                await refreshAssets()
                lastMessage = "Saved \(item.displayName) to your library."
            } catch {
                lastMessage = "\(item.displayName) could not be saved."
            }
        }
    }

    public func removeCapture(_ item: CaptureHistoryItem) {
        guard let runtime else { return }
        Task {
            await runtime.removeCapture(item.id)
            await refreshCaptureHistory()
        }
    }

    public func clearCaptureHistory() {
        guard let runtime else { return }
        Task {
            await runtime.clearCaptureHistory()
            await refreshCaptureHistory()
        }
    }

    private func handleAutomaticIngest(_ record: AssetRecord) async {
        guard record.kind == .video else { return }
        if !assets.contains(where: { $0.id == record.id }) {
            await refreshAssets()
        }
        guard imageEditor == nil, pdfEditor == nil, textEditor == nil else {
            lastMessage = "Recording added to the library. Close the current editor to open it."
            return
        }
        if let editor {
            let track = await runtime?.eventTracks(for: [record.id])[record.id]
            guard editor.appendCapturedAsset(record, eventTrack: track) else { return }
            selectedWorkspace = .video
            lastMessage = "Added the recording to the end of your timeline."
            return
        }
        guard record.duration != nil else {
            lastMessage = "The recording was imported, but it has no playable duration."
            return
        }
        openEditor(for: record.id)
        if editor != nil {
            lastMessage = "Recording opened in a new timeline."
        }
    }

    public func selectFolder(_ path: String?) {
        if isSearching { clearSearch() }
        closeOpenEditors()
        guard selectedFolderPath != path || selectedWorkspace != .inbox else { return }
        folderBackHistory.append(selectedFolderPath)
        folderForwardHistory.removeAll()
        selectedWorkspace = .inbox
        selectedFolderPath = path
        selection.deselectAll()
    }

    public func navigateBack() {
        guard let destination = folderBackHistory.popLast() else { return }
        closeOpenEditors()
        folderForwardHistory.append(selectedFolderPath)
        selectedFolderPath = destination
        selectedWorkspace = .inbox
        selection.deselectAll()
    }

    public func navigateForward() {
        guard let destination = folderForwardHistory.popLast() else { return }
        closeOpenEditors()
        folderBackHistory.append(selectedFolderPath)
        selectedFolderPath = destination
        selectedWorkspace = .inbox
        selection.deselectAll()
    }

    public func runPaletteCommand(_ id: CommandID) {
        if AppCommandRouter.menuCommandIDs.contains(id) {
            AppCommandRouter.run(id, in: self)
            isCommandPalettePresented = false
            return
        }
        if let imageEditor, CommandRegistry.command(id: id)?.category == .image {
            imageEditor.runImageCommand(id.rawValue)
            isCommandPalettePresented = false
            return
        }
        if let pdfEditor, CommandRegistry.command(id: id)?.category == .pdf {
            pdfEditor.runPDFCommand(id.rawValue)
            isCommandPalettePresented = false
            return
        }
        if CommandRegistry.command(id: id)?.category == .text {
            switch id.rawValue {
            case "text.create":
                createScratchTextEditor()
            case "tex.compile":
                textEditor?.requestTeXCompile()
            case "tex.diagnostics":
                let count = textEditor?.texDiagnostics.count ?? 0
                lastMessage =
                    count == 0
                    ? "No LaTeX diagnostics are available. Build the document first."
                    : "\(count) LaTeX diagnostic\(count == 1 ? "" : "s") are shown below the editor."
            default:
                assistantDraft = "Run \(id.rawValue) for the active text file."
                isInspectorVisible = true
                lastMessage = "Command prepared in the Text inspector's Chat tab."
            }
            isCommandPalettePresented = false
            return
        }
        guard let editor else {
            lastMessage =
                "Open a document to run \(CommandRegistry.command(id: id)?.title ?? id.rawValue)."
            return
        }
        switch id.rawValue {
        case "splitClip": editor.splitAtPlayhead()
        case "addZoom":
            if let item = editor.selectedItem { editor.addZoom(to: item.id) }
        case "autoZoomFromClicks": editor.autoZoomSelectedClip()
        default:
            assistantDraft = "Run command \(id.rawValue) for the current selection."
            lastMessage = "Command prepared in Chat with current editor context."
        }
        isCommandPalettePresented = false
    }

    public func toggleFolderExpansion(_ path: String) {
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
        }
        UserDefaults.standard.set(Array(expandedFolders).sorted(), forKey: "reel.expandedFolders")
        Task { await refreshFolderTree() }
    }

    public func createFolder(named name: String, in parent: String) {
        guard let runtime else { return }
        Task {
            do {
                let path = try await runtime.createFolder(named: name, in: parent)
                expandedFolders.insert(parent)
                await refreshFolderTree()
                selectFolder(path)
                registerUndo(actionName: "Create Folder") { target in
                    target.trashFolder(path)
                }
            } catch {
                lastMessage = "The folder could not be created."
            }
        }
    }

    public func renameFolder(_ path: String, to name: String) {
        guard let runtime else { return }
        let oldName = URL(fileURLWithPath: path).lastPathComponent
        Task {
            do {
                let updated = try await runtime.renameFolder(path, to: name)
                if selectedFolderPath == path { selectedFolderPath = updated }
                await refreshAssets()
                registerUndo(actionName: "Rename Folder") { target in
                    target.renameFolder(updated, to: oldName)
                }
            } catch {
                lastMessage = "The folder could not be renamed."
            }
        }
    }

    public func renameAsset(_ id: AssetID, to name: String) {
        _ = scheduleAssetRename(id, to: name, registersUndoOnSuccess: true)
    }

    @discardableResult
    private func scheduleAssetRename(
        _ id: AssetID,
        to name: String,
        registersUndoOnSuccess: Bool,
        undoToken: AssetRenameUndoToken? = nil
    ) -> Bool {
        guard let runtime, let original = assets.first(where: { $0.id == id }),
            !renamingAssetIDs.contains(id)
        else { return false }
        renamingAssetIDs.insert(id)
        Task {
            defer { renamingAssetIDs.remove(id) }
            do {
                let renamed = try await runtime.renameAsset(id, to: name)
                let relocatedURL = libraryRoot.appendingPathComponent(renamed.relativePath)
                relocateOpenEditorSource(
                    for: id,
                    to: relocatedURL,
                    displayName: renamed.displayName
                )
                if let index = assets.firstIndex(where: { $0.id == id }) {
                    assets[index] = renamed
                }
                await refreshAssets()
                guard renamed.displayName != original.displayName else {
                    if let undoToken {
                        undoToken.manager?.removeAllActions(withTarget: undoToken)
                    }
                    return
                }
                if registersUndoOnSuccess {
                    registerAssetRenameUndo(
                        id,
                        targetName: original.displayName,
                        inverseName: renamed.displayName
                    )
                }
                lastMessage = "Renamed to \(renamed.displayName)."
            } catch {
                if let undoToken {
                    // UndoManager requires the inverse to be registered while
                    // undo/redo is executing, before this async move finishes.
                    // A unique target lets us remove only that failed rename's
                    // inverse without erasing other filenames or content edits.
                    undoToken.manager?.removeAllActions(withTarget: undoToken)
                }
                lastMessage = "The file could not be renamed. Choose a different name."
            }
        }
        return true
    }

    /// Registers the inverse synchronously when an undo or redo handler runs,
    /// before its asynchronous filesystem move starts. Waiting until that move
    /// finishes would miss NSUndoManager's redo group and turn Redo into a
    /// second Undo entry.
    private func registerAssetRenameUndo(
        _ id: AssetID,
        targetName: String,
        inverseName: String,
        token: AssetRenameUndoToken? = nil
    ) {
        let manager = token?.manager ?? renameUndoManager(for: id)
        let token = token ?? AssetRenameUndoToken(manager: manager)
        let opensGroup = manager.groupingLevel == 0
        if opensGroup { manager.beginUndoGrouping() }
        // UndoManager keeps an unowned target. Capturing this operation token
        // in its own handler keeps it alive exactly as long as the action is on
        // an undo or redo stack.
        manager.registerUndo(withTarget: token) { [weak self, token] _ in
            guard let self else { return }
            guard
                self.scheduleAssetRename(
                    id,
                    to: targetName,
                    registersUndoOnSuccess: false,
                    undoToken: token
                )
            else { return }
            self.registerAssetRenameUndo(
                id,
                targetName: inverseName,
                inverseName: targetName,
                token: token
            )
        }
        manager.setActionName("Rename File")
        if opensGroup { manager.endUndoGrouping() }
    }

    /// Filename changes made inside an editor join that editor's history so
    /// Command-Z preserves the real ordering between content edits and renames.
    private func renameUndoManager(for assetID: AssetID) -> UndoManager {
        if let textEditor,
            textEditor.document.files.contains(where: { $0.assetID == assetID })
        {
            return textEditor.undoManager
        }
        if imageEditor?.document.sourceAssetID == assetID {
            return imageEditor?.undoManager ?? undoManager
        }
        if pdfEditor?.document.sourceAssetID == assetID {
            return pdfEditor?.undoManager ?? undoManager
        }
        return undoManager
    }

    /// Renames the file currently shown by the text workspace. Library-backed
    /// files go through LibraryStore so the file, metadata, search index, and
    /// undo history stay in sync. Scratch buffers only rename their persisted
    /// document entry because they do not have a standalone file yet.
    public func renameOpenTextFile(to name: String) {
        guard let textEditor, let activeFile = textEditor.activeFile else { return }
        if let assetID = activeFile.assetID {
            renameAsset(assetID, to: name)
            return
        }

        guard textEditor.sourceURL == nil else {
            lastMessage = "This project file must be added to the library before it can be renamed."
            return
        }
        if textEditor.renameActiveScratchFile(to: name) {
            lastMessage = "Renamed to \(textEditor.activeFile?.relativePath ?? name)."
            Task { await refreshScratchBuffers() }
        } else {
            lastMessage = textEditor.notice ?? "The file could not be renamed."
        }
    }

    private func relocateOpenEditorSource(
        for assetID: AssetID,
        to url: URL,
        displayName: String
    ) {
        if imageEditor?.document.sourceAssetID == assetID {
            imageEditor?.relocateSource(to: url, displayName: displayName)
        }
        if pdfEditor?.document.sourceAssetID == assetID {
            pdfEditor?.relocateSource(to: url, displayName: displayName)
        }
        if let textEditor,
            textEditor.document.files.contains(where: { $0.assetID == assetID })
        {
            _ = textEditor.relocateSource(
                for: assetID,
                to: url,
                displayName: displayName
            )
        }
    }

    public func moveSelectedAssets(to folder: String) {
        moveAssets(Array(selection.selected), to: folder)
    }

    public func moveAssets(_ ids: [AssetID], to folder: String) {
        guard let runtime, !ids.isEmpty else { return }
        let oldParents = Dictionary(grouping: ids) { id in
            assets.first(where: { $0.id == id })?.relativePath
                .deletingLastPathComponent.deletingMediaPrefix ?? "Inbox"
        }
        Task {
            do {
                _ = try await runtime.moveAssets(ids, to: folder)
                await refreshAssets()
                selection.deselectAll()
                registerUndo(actionName: "Move Assets") { target in
                    for (parent, ids) in oldParents {
                        target.moveAssets(ids, to: parent)
                    }
                }
            } catch {
                lastMessage = "The selected files could not be moved."
            }
        }
    }

    public func moveFolder(_ path: String, to parent: String) {
        guard let runtime else { return }
        let oldParent = path.deletingLastPathComponent
        Task {
            do {
                let updated = try await runtime.moveFolder(path, to: parent)
                if selectedFolderPath == path { selectedFolderPath = updated }
                await refreshAssets()
                registerUndo(actionName: "Move Folder") { target in
                    target.moveFolder(updated, to: oldParent)
                }
            } catch {
                lastMessage = "The folder could not be moved."
            }
        }
    }

    public func trashFolder(_ path: String) {
        guard let runtime else { return }
        Task {
            do {
                let receipt = try await runtime.trashFolder(path)
                if selectedFolderPath == path { selectedFolderPath = "Inbox" }
                await refreshAssets()
                registerUndo(actionName: "Move Folder to Trash") { target in
                    target.restoreFolder(receipt)
                }
            } catch {
                lastMessage = "The folder could not be moved to Trash."
            }
        }
    }

    /// Whether the right-hand inspector rail applies to the current workspace.
    ///
    /// Only the media editors carry a dedicated inspector (PDF layers, image
    /// layers, timeline effects). While browsing the library, "Get Info" on an
    /// item replaces the pane, so both the rail and its toolbar toggle hide.
    public var showsEditorInspector: Bool {
        editor != nil || imageEditor != nil || pdfEditor != nil || textEditor != nil
    }

    /// Resizes the inspector column, holding it inside the draggable range and
    /// remembering the result for the next launch.
    ///
    /// Clamping lives here rather than in a `didSet`: `@Observable` turns the
    /// property into a computed one, so assigning to it from its own observer
    /// recurses until the stack runs out.
    public func setInspectorWidth(_ width: Double) {
        let width = InspectorLayout.clamped(width)
        guard width != inspectorWidth else { return }
        inspectorWidth = width
        InspectorLayout.store(width)
    }

    /// The sidebar shows the library's folder name rather than its full path,
    /// so opening it in Finder is how you get at the location itself.
    public func revealLibraryRootInFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [libraryRoot.path(percentEncoded: false)]
        try? process.run()
    }

    public func revealSelectionInFinder() {
        guard let runtime else { return }
        Task { await runtime.revealInFinder(Array(selection.selected)) }
    }

    public func quickLookSelection() {
        guard let runtime else { return }
        let ids = Array(selection.selected)
        Task {
            let urls = await runtime.urls(for: ids)
            guard !urls.isEmpty else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            process.arguments = ["-p"] + urls.map(\.path)
            try? process.run()
        }
    }

    public func locateMissingAsset(_ id: AssetID, at url: URL) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.locate(assetID: id, at: url)
                await refreshAssets()
                lastMessage = "Missing media located."
            } catch {
                lastMessage = "That file does not match the missing original."
            }
        }
    }

    public func confirmMigration() {
        guard let plan = pendingMigrationPlan else { return }
        pendingMigrationPlan = nil
        Task {
            do {
                try await AppRuntime.migrate(plan, at: libraryRoot)
                hasStarted = false
                await start()
                lastMessage = "Library upgraded. Revert remains available for 30 days."
            } catch {
                pendingMigrationPlan = plan
                lastMessage = "The library upgrade could not be completed; no files were changed."
            }
        }
    }

    public func deferMigration() {
        pendingMigrationPlan = nil
        lastMessage = "The library was left unchanged. Reopen Clip when you're ready to upgrade."
    }

    public func revertLibraryMigration() {
        guard canRevertMigration else { return }
        Task {
            let activeRuntime = runtime
            runtime = nil
            await activeRuntime?.stop()
            do {
                try await AppRuntime.revertMigration(at: libraryRoot)
                canRevertMigration = false
                assets = []
                isWatching = false
                lastMessage = "Migration reverted. Quit Clip before opening this library with v1."
            } catch {
                runtime = activeRuntime
                lastMessage = "The migration could not be reverted."
            }
        }
    }

    public func refreshShortcuts() {
        shortcutRow = ShortcutRowModel(result: shortcutReader.read())
    }

    public func refreshSystemAccess() {
        refreshShortcuts()
        guard let runtime else { return }
        Task {
            clickTrackingState = await runtime.startClickTracking()
            editor?.setClickTrackingState(clickTrackingState)
        }
    }

    public func requestClickTrackingAccess() {
        EventTapRecorder.requestAuthorization()
        refreshSystemAccess()
    }

    public func grantCaptureDirectoryAccess(_ url: URL) {
        guard let runtime else {
            lastMessage = "The library is still opening. Try again in a moment."
            return
        }
        Task {
            do {
                let status = try await runtime.grantCaptureDirectoryAccess(url)
                captureDirectory = status.url
                isCaptureDirectoryWatched = status.isWatching
                lastMessage = "Watching \(status.url.lastPathComponent) for new captures."
            } catch {
                isCaptureDirectoryWatched = false
                lastMessage = "Clip couldn't access that capture folder."
            }
        }
    }

    public func accept(_ urls: [URL], source: IngestSource) {
        guard !urls.isEmpty else { return }
        showWorkspace(WorkspaceRouter.destination(for: urls[0]))
        ingestCount += urls.count

        Task {
            defer { ingestCount -= urls.count }
            guard let runtime else {
                lastMessage = "The library is still opening. Try the drop again in a moment."
                return
            }
            for url in urls {
                do {
                    _ = try await runtime.ingest(url, source: source)
                } catch {
                    lastMessage =
                        "Couldn't read \(url.lastPathComponent). It may still be writing — try again in a moment."
                }
            }
            await refreshAssets()
        }
    }

    public func acceptDrop(_ urls: [URL]) {
        accept(urls, source: .drop)
    }

    public func selectAsset(_ id: AssetID, modifiers: EventModifiers = []) {
        selection.click(id, modifiers: modifiers)
    }

    public func activateAsset(_ id: AssetID) {
        guard let asset = assets.first(where: { $0.id == id }) else { return }
        selection.selectOnly(id)
        guard !asset.isMissing else {
            lastMessage = "Locate this missing file before opening it."
            return
        }
        switch AssetActivationRoute(asset: asset) {
        case .videoEditor: openEditor(for: id)
        case .photoEditor: openImageEditor(for: id)
        case .pdfEditor: openPDFEditor(for: id)
        case .textEditor: openTextEditor(for: id)
        case .conversion: openConverter(for: asset)
        case .none:
            showWorkspace(.convert)
            lastMessage = "This file is available in Convert."
        }
    }

    private func openConverter(for asset: AssetRecord) {
        showWorkspace(.convert)
        guard !conversionQueue.contains(where: { $0.asset.id == asset.id }),
            let runtime
        else { return }
        Task {
            do {
                let inputURL = try await runtime.url(for: asset.id)
                var item = ConversionQueueItem(
                    asset: asset,
                    inputURL: inputURL,
                    capabilities: conversionCapabilities
                )
                item.setConflictPolicy(conversionConflictPolicy)
                conversionQueue.append(item)
            } catch {
                lastMessage = "Couldn't add \(asset.displayName) to Convert."
            }
        }
    }

    public func activateSearchHit(_ hit: SearchHit, moment: SearchMoment? = nil) {
        guard let asset = assets.first(where: { $0.id == hit.assetID }) else { return }
        let destination = moment?.start ?? hit.moments.first?.start
        clearSearch()
        selection.selectOnly(asset.id)
        guard !asset.isMissing else {
            lastMessage = "Locate this missing file before opening it."
            return
        }
        if asset.kind == .video {
            openEditor(for: asset.id, initialTime: destination)
        } else {
            activateAsset(asset.id)
        }
    }

    public func indexedText(at time: RationalTime, in assetID: AssetID) async -> [OCRSpan] {
        guard let runtime else { return [] }
        return (try? await runtime.indexedText(at: time, in: assetID)) ?? []
    }

    public func searchLibrary(for text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        closeOpenEditors()
        searchQuery = query
        focusSearch()
    }

    public func reindexSemanticSearch() {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.rebuildSemanticIndex()
                embeddingModelNeedsReindex = false
                lastMessage = "Semantic search is rebuilding in the background."
            } catch {
                lastMessage = "Semantic search could not be rebuilt."
            }
        }
    }

    public func clearSearch() {
        searchQuery = ""
    }

    public func focusSearch() {
        searchFocusRequest += 1
    }

    public func requestTrashSelectedAssets() {
        let ids = Array(selection.selected)
        guard !ids.isEmpty, let runtime else { return }
        Task {
            do {
                let projects = try await runtime.projectsReferencing(assetIDs: ids)
                if projects.isEmpty {
                    await performTrash(ids)
                } else {
                    pendingTrashConfirmation = TrashConfirmation(
                        assetIDs: ids,
                        projectNames: projects.map(\.name)
                    )
                }
            } catch {
                lastMessage = "Clip couldn't check whether those files are in a project."
            }
        }
    }

    public func confirmTrash() {
        guard let confirmation = pendingTrashConfirmation else { return }
        pendingTrashConfirmation = nil
        Task { await performTrash(confirmation.assetIDs) }
    }

    public func cancelTrash() {
        pendingTrashConfirmation = nil
    }

    public func undoLibraryAction() {
        undoManager.undo()
    }

    public func redoLibraryAction() {
        undoManager.redo()
    }

    public func acceptPicker(_ urls: [URL]) {
        accept(urls, source: .picker)
    }

    public var isConverting: Bool {
        conversionQueue.contains { item in
            if case .converting = item.status { return true }
            return false
        }
    }

    public var shouldSuggestLibreOffice: Bool {
        conversionCapabilities.allowsExternalProcesses
            && !conversionCapabilities.isLibreOfficeAvailable
    }

    public var hasConvertibleItems: Bool {
        conversionQueue.contains { item in
            switch item.status {
            case .waiting, .failed, .cancelled, .skipped:
                break
            case .converting, .completed:
                return false
            }
            if case .unsupported = item.plan.backend { return false }
            return true
        }
    }

    /// Phase-V targets the open Markdown editor can reach in this build channel.
    public var textEditorExportTargets: [TargetFormat] {
        guard textEditor?.language == .markdown, textEditor?.sourceURL != nil else { return [] }
        let candidates: [TargetFormat] = [.html, .pdf, .docx]
        let planner = ConversionPlanner(capabilities: conversionCapabilities)
        return candidates.filter { target in
            planner.plan(from: ConversionFormats.markdown, to: target.formatID) != nil
        }
    }

    /// Saves the open Markdown file and hands it to the shared conversion queue.
    public func enqueueTextEditorExport(as target: TargetFormat) {
        guard textEditorExportTargets.contains(target),
            let editor = textEditor,
            let assetID = editor.activeFile?.assetID,
            let asset = assets.first(where: { $0.id == assetID }),
            let inputURL = editor.sourceURL
        else {
            lastMessage = "Save this Markdown file to the library before exporting it."
            return
        }
        editor.saveNow()
        if let index = conversionQueue.firstIndex(where: { $0.asset.id == assetID }) {
            conversionQueue[index].selectTarget(target)
        } else {
            var item = ConversionQueueItem(
                asset: asset,
                inputURL: inputURL,
                target: target,
                capabilities: conversionCapabilities
            )
            item.setConflictPolicy(conversionConflictPolicy)
            conversionQueue.append(item)
        }
        showWorkspace(.convert)
    }

    public func enqueueForConversion(_ urls: [URL], source: IngestSource) {
        guard !urls.isEmpty else { return }
        showWorkspace(.convert)
        ingestCount += urls.count

        Task {
            defer { ingestCount -= urls.count }
            guard let runtime else {
                lastMessage = "The library is still opening. Try the drop again in a moment."
                return
            }
            for url in urls {
                let hasSecurityScope =
                    source == .picker
                    && url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let asset = try await runtime.ingest(url, source: source)
                    let inputURL = try await runtime.url(for: asset.id)
                    if !conversionQueue.contains(where: { $0.asset.id == asset.id }) {
                        var item = ConversionQueueItem(
                            asset: asset,
                            inputURL: inputURL,
                            capabilities: conversionCapabilities
                        )
                        item.setConflictPolicy(conversionConflictPolicy)
                        conversionQueue.append(item)
                    }
                } catch {
                    lastMessage = "Couldn't add \(url.lastPathComponent) to the conversion queue."
                }
            }
            await refreshAssets()
        }
    }

    public func selectConversionTarget(_ target: TargetFormat, for id: UUID) {
        guard let index = conversionQueue.firstIndex(where: { $0.id == id }) else { return }
        if case .converting = conversionQueue[index].status { return }
        conversionQueue[index].selectTarget(target)
    }

    public func availableConversionTargets(for kind: AssetKind) -> [TargetFormat] {
        let items = conversionQueue.filter { $0.asset.kind == kind }
        guard let first = items.first else { return [] }
        let common = items.dropFirst().reduce(Set(first.availableTargets)) { targets, item in
            targets.intersection(item.availableTargets)
        }
        return TargetFormat.allCases.filter { common.contains($0) }
    }

    public func selectConversionTarget(_ target: TargetFormat, forGroup kind: AssetKind) {
        for index in conversionQueue.indices where conversionQueue[index].asset.kind == kind {
            conversionQueue[index].selectTarget(target)
        }
    }

    public func applyConversionPreset(_ preset: ConversionPreset, for id: UUID) {
        guard let index = conversionQueue.firstIndex(where: { $0.id == id }) else { return }
        conversionQueue[index].applyPreset(preset)
    }

    public func setConversionMetadataStripping(_ enabled: Bool, for id: UUID) {
        guard let index = conversionQueue.firstIndex(where: { $0.id == id }) else { return }
        conversionQueue[index].setStripMetadata(enabled)
    }

    public func retryConversion(_ id: UUID) {
        guard let index = conversionQueue.firstIndex(where: { $0.id == id }) else { return }
        conversionQueue[index].retry()
    }

    public func setConversionConcurrency(_ value: Int) {
        guard !isConverting else { return }
        conversionConcurrency = min(8, max(1, value))
        UserDefaults.standard.set(conversionConcurrency, forKey: "clip.convert.concurrency")
    }

    public func setConversionDestination(folder: URL, destination: ExportDestination) {
        guard !isConverting else { return }
        conversionDestinationFolder = folder.standardizedFileURL
        conversionDestination = destination
        UserDefaults.standard.set(
            conversionDestinationFolder.path,
            forKey: "clip.convert.destinationFolder"
        )
        UserDefaults.standard.set(
            try? JSONEncoder().encode(destination),
            forKey: "clip.convert.destination"
        )
    }

    public func setConversionConflictPolicy(_ policy: ConversionConflictPolicy) {
        guard !isConverting else { return }
        conversionConflictPolicy = policy
        UserDefaults.standard.set(policy.rawValue, forKey: "clip.convert.conflictPolicy")
        for index in conversionQueue.indices {
            conversionQueue[index].setConflictPolicy(policy)
        }
    }

    public func removeConversion(_ id: UUID) {
        guard let item = conversionQueue.first(where: { $0.id == id }) else { return }
        if case .converting = item.status { return }
        conversionQueue.removeAll { $0.id == id }
    }

    public func cancelConversion(_ id: UUID) {
        guard
            conversionQueue.contains(where: { item in
                item.id == id && item.status == .converting
            }), let runtime
        else { return }
        Task { await runtime.cancelConversion(id) }
    }

    public func cancelAllConversions() {
        guard isConverting, let runtime else { return }
        Task { await runtime.cancelAllConversions() }
    }

    public func convertQueuedItems() {
        guard !isConverting, conversionTask == nil, let runtime else { return }

        var jobs: [BatchConversionJob] = []
        var reservedOutputs: Set<URL> = []
        var preflightFailures = 0

        for index in conversionQueue.indices {
            switch conversionQueue[index].status {
            case .waiting, .failed, .cancelled, .skipped:
                break
            case .converting, .completed:
                continue
            }
            if case .unsupported(let reason) = conversionQueue[index].plan.backend {
                conversionQueue[index].status = .failed(reason)
                continue
            }
            let item = conversionQueue[index]
            let output: URL
            do {
                guard
                    let resolved = try resolvedConversionOutput(
                        for: item,
                        index: jobs.count + 1,
                        reserved: &reservedOutputs
                    )
                else {
                    conversionQueue[index].status = .skipped(
                        "An output already exists. Change the conflict policy to convert it."
                    )
                    continue
                }
                output = resolved
            } catch {
                conversionQueue[index].status = .failed(error.localizedDescription)
                preflightFailures += 1
                continue
            }
            conversionQueue[index].progress = 0
            conversionQueue[index].status = .converting
            jobs.append(
                BatchConversionJob(
                    id: item.id,
                    plan: item.plan,
                    input: item.inputURL,
                    output: output
                )
            )
        }
        guard !jobs.isEmpty else { return }

        conversionAggregateProgress = 0
        conversionCompletedCount = 0
        conversionBatchTotal = jobs.count
        conversionTask = Task {
            var successURLs: [URL] = []
            var failedCount = preflightFailures
            defer { conversionTask = nil }
            do {
                let stream = await runtime.convert(jobs, concurrency: conversionConcurrency)
                for try await update in stream {
                    guard let itemID = update.itemID,
                        let queueIndex = conversionQueue.firstIndex(where: { $0.id == itemID })
                    else { continue }
                    conversionQueue[queueIndex].progress = min(update.itemProgress, 1)
                    conversionAggregateProgress = update.aggregateProgress
                    conversionCompletedCount = update.completed
                    switch update.outcome {
                    case .succeeded(let output):
                        conversionQueue[queueIndex].status = .completed(output)
                        successURLs.append(output)
                    case .failed(let reason):
                        conversionQueue[queueIndex].status = .failed(reason)
                        failedCount += 1
                    case .cancelled:
                        conversionQueue[queueIndex].status = .cancelled
                    case nil:
                        break
                    }
                }
                performConversionCompletionAction(for: successURLs)
                if failedCount > 0 {
                    lastMessage =
                        "Converted \(successURLs.count) of \(jobs.count + preflightFailures). \(failedCount) need attention."
                } else {
                    lastMessage =
                        "Converted \(successURLs.count) file\(successURLs.count == 1 ? "" : "s")."
                }
            } catch is CancellationError {
                for index in conversionQueue.indices {
                    if case .converting = conversionQueue[index].status {
                        conversionQueue[index].status = .cancelled
                    }
                }
                lastMessage = "Conversion cancelled."
            } catch {
                for index in conversionQueue.indices {
                    if case .converting = conversionQueue[index].status {
                        conversionQueue[index].status = .failed(error.localizedDescription)
                    }
                }
                lastMessage = "The conversion batch couldn't be completed."
            }
        }
    }

    public func clearMessage() {
        lastMessage = nil
    }

    public func sendAssistantMessage() {
        let prompt = assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isAssistantWorking, let runtime,
            let session = assistantSession(runtime: runtime)
        else { return }
        assistantDraft = ""
        assistantMessages.append(AssistantMessage(role: .user, text: prompt))
        isAssistantWorking = true
        let turnID = UUID().uuidString.lowercased()
        let digest = session.digest
        let context = session.context
        let settings = aiSettings

        Task {
            defer { isAssistantWorking = false }
            do {
                let provider = try await settings.provider()
                let turn = try await AssistantTurnRunner().run(
                    prompt: prompt,
                    turnID: turnID,
                    provider: provider,
                    policy: settings.confirmationPolicy,
                    digest: digest,
                    context: context
                )
                var responseParts: [String] = []
                if !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    responseParts.append(turn.text)
                }
                for result in turn.results {
                    responseParts.append(result.message)
                }
                for (invocation, result) in zip(turn.invocations, turn.results)
                where result.requiresConfirmation && result.patch == nil
                    && supportsAssistantConfirmation(invocation)
                {
                    pendingAssistantActions.append(
                        PendingAssistantAction(
                            name: invocation.name,
                            result: result,
                            invocation: invocation
                        )
                    )
                    responseParts.append("Review this file operation before applying.")
                }
                if let combinedPatch = turn.combinedPatch {
                    let requiresConfirmation = turn.results.contains(where: \.requiresConfirmation)
                    if requiresConfirmation {
                        let result = ToolResult(
                            callID: turnID,
                            message: "Apply \(combinedPatch.ops.count) assistant operations?",
                            patch: combinedPatch,
                            requiresConfirmation: true
                        )
                        pendingAssistantActions.append(
                            PendingAssistantAction(name: "assistant.turn", result: result)
                        )
                        responseParts.append("Review the complete edit plan before applying.")
                    } else if let editor {
                        try editor.perform(combinedPatch)
                    } else {
                        throw ToolExecutorError.invalidArguments(
                            "A timeline edit was returned while the text editor was active"
                        )
                    }
                }
                if responseParts.isEmpty {
                    responseParts.append("No edit was requested by the provider.")
                }
                assistantMessages.append(
                    AssistantMessage(role: .assistant, text: responseParts.joined(separator: "\n")))
                await settings.refresh()
            } catch {
                assistantMessages.append(
                    AssistantMessage(
                        role: .status,
                        text: error.localizedDescription
                    ))
            }
        }
    }

    public func approveAssistantAction(_ id: String) {
        guard let index = pendingAssistantActions.firstIndex(where: { $0.id == id }) else {
            return
        }
        let action = pendingAssistantActions[index]
        if let patch = action.result.patch, let editor {
            do {
                try editor.perform(patch)
                assistantMessages.append(
                    AssistantMessage(role: .status, text: action.result.message))
                pendingAssistantActions.removeAll { $0.id == id }
            } catch {
                assistantMessages.append(
                    AssistantMessage(role: .status, text: error.localizedDescription))
            }
            return
        }
        guard let invocation = action.invocation, let runtime,
            let session = assistantSession(runtime: runtime), !isAssistantWorking
        else { return }
        isAssistantWorking = true
        let context = session.context
        let policy = aiSettings.confirmationPolicy
        Task {
            defer { isAssistantWorking = false }
            do {
                let result = try await ToolExecutor().execute(
                    invocation,
                    turnID: invocation.callID,
                    policy: policy,
                    context: context,
                    confirmed: true
                )
                pendingAssistantActions.removeAll { $0.id == id }
                assistantMessages.append(AssistantMessage(role: .status, text: result.message))
            } catch {
                assistantMessages.append(
                    AssistantMessage(role: .status, text: error.localizedDescription))
            }
        }
    }

    public func rejectAssistantAction(_ id: String) {
        pendingAssistantActions.removeAll { $0.id == id }
        assistantMessages.append(AssistantMessage(role: .status, text: "Action skipped."))
    }

    private func assistantToolContext(
        editor: EditorViewModel,
        runtime: AppRuntime
    ) -> ToolExecutionContext {
        var context = editor.toolExecutionContext()
        configureSharedAssistantServices(&context, runtime: runtime)
        return context
    }

    private func assistantSession(
        runtime: AppRuntime
    ) -> (digest: ContextDigest, context: ToolExecutionContext)? {
        if let editor {
            return (
                editor.assistantContextDigest(),
                assistantToolContext(editor: editor, runtime: runtime)
            )
        }
        guard let textEditor,
            let emptyProject = try? ProjectDocument(
                id: .generate(),
                name: textEditor.activeFile?.relativePath ?? "Text document",
                createdAt: .now,
                modifiedAt: .now
            )
        else { return nil }
        var context = ToolExecutionContext(
            document: emptyProject,
            assets: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }),
            eventTracks: [:],
            resolving: { assetID in try await runtime.url(for: assetID) }
        )
        configureSharedAssistantServices(&context, runtime: runtime)
        let digest = ContextDigest(
            projectName: textEditor.activeFile?.relativePath ?? "Text document",
            duration: 0,
            canvas: "text:\(textEditor.language.rawValue)",
            selectedItemID: nil,
            items: []
        )
        return (digest, context)
    }

    private func configureSharedAssistantServices(
        _ context: inout ToolExecutionContext,
        runtime: AppRuntime
    ) {
        context.searching = { query in try await runtime.search(query) }
        context.searchingWithin = { assetID, text in
            try await runtime.searchWithin(assetID, text: text)
        }
        context.readingText = { assetID, time in
            try await runtime.indexedText(at: time, in: assetID)
        }
        context.searchingSimilar = { assetID, limit in
            try await runtime.similarAssets(to: assetID, limit: limit)
        }
        context.conversionDestination = conversionDestinationFolder
        context.conversionCapabilities = conversionCapabilities
        context.converting = { jobs in
            let stream = await runtime.convert(jobs)
            var outcomes: [UUID: BatchItemOutcome] = [:]
            for try await progress in stream {
                if let id = progress.itemID, let outcome = progress.outcome {
                    outcomes[id] = outcome
                }
            }
            return jobs.map { job in
                outcomes[job.id]
                    ?? .failed("The conversion ended without a result")
            }
        }
        context.textCommand = { [weak self] request in
            guard let self else { throw ToolExecutorError.textUnavailable }
            return try await self.executeTextTool(request)
        }
    }

    private func supportsAssistantConfirmation(_ invocation: ToolInvocation) -> Bool {
        if invocation.name == "convert.run" || invocation.name == "text.export"
            || invocation.name == "text.create" || invocation.name == "text.setLanguage"
            || invocation.name == "text.format" || invocation.name == "tex.compile"
        {
            return true
        }
        guard invocation.name == "runCommand",
            case .object(let fields) = invocation.arguments,
            let idValue = fields["id"], case .string(let id) = idValue
        else { return false }
        return [
            "convert.run", "text.export", "text.create", "text.setLanguage", "text.format",
            "tex.compile",
        ].contains(id)
    }

    private func executeTextTool(_ request: TextToolRequest) async throws -> String {
        switch request {
        case .create(let name, let rawLanguage, let contents):
            guard editor == nil, imageEditor == nil, pdfEditor == nil, let runtime
            else {
                throw ToolExecutorError.invalidArguments(
                    "Close the current editor before creating another text buffer"
                )
            }
            if let textEditor {
                guard !textEditor.hasExternalConflict,
                    !textEditor.isDetached || textEditor.hasSavedDetachedCopy
                else {
                    throw ToolExecutorError.invalidArguments(
                        "Resolve or save the active text file before creating another buffer"
                    )
                }
                textEditor.stop()
                self.textEditor = nil
            }
            guard Int64(contents.utf8.count) <= TextFileLoader.maximumByteSize else {
                throw ToolExecutorError.invalidArguments("Initial text exceeds the 20 MB limit")
            }
            var buffer = try await runtime.createScratchTextBuffer()
            var document = buffer.document
            guard let fileID = document.files.first?.id else {
                throw ToolExecutorError.textUnavailable
            }
            let safeName = try validatedTextFileName(name ?? "Untitled.txt")
            _ = try document.apply(.renameFile(fileID, safeName))
            let language =
                rawLanguage.map(normalizedLanguage)
                ?? LanguageDetector.detect(path: safeName, contents: contents)
            _ = try document.apply(
                .setLanguage(fileID, language, explicit: rawLanguage != nil)
            )
            try await runtime.saveScratchTextDocument(document)
            try await runtime.saveScratchTextContents(Data(contents.utf8), for: document.id)
            buffer = ScratchTextBuffer(
                document: document,
                contents: LoadedTextFile(
                    text: contents,
                    encoding: .utf8,
                    lineEnding: TextFileLoader.lineEnding(in: contents)
                )
            )
            openScratchTextEditor(buffer, runtime: runtime)
            await refreshScratchBuffers()
            return "Created \(safeName) as \(language.rawValue)."
        case .setLanguage(let rawLanguage):
            guard let textEditor else { throw ToolExecutorError.textUnavailable }
            let language = normalizedLanguage(rawLanguage)
            textEditor.setLanguage(language)
            return
                "Set \(textEditor.activeFile?.relativePath ?? "the active file") to \(language.rawValue)."
        case .format(let request):
            guard let textEditor else { throw ToolExecutorError.textUnavailable }
            let changeCount = try textEditor.applyToolFormat(request)
            return changeCount == 0
                ? "The active text already matched the requested format."
                : "Applied \(changeCount) text change\(changeCount == 1 ? "" : "s") with undo available."
        case .compileTeX:
            guard let textEditor, textEditor.language == .latex else {
                throw ToolExecutorError.invalidArguments(
                    "Open a LaTeX source file before compiling")
            }
            switch await textEditor.compileForTool() {
            case .idle: return "LaTeX compile did not start."
            case .compiling: return "LaTeX compile is still running."
            case .succeeded:
                return
                    "LaTeX compiled successfully with \(textEditor.texDiagnostics.count) diagnostic\(textEditor.texDiagnostics.count == 1 ? "" : "s")."
            case .paused(let reason): return "LaTeX compile paused: \(reason)"
            case .failed(let reason):
                return "LaTeX compile failed: \(reason)\nRun tex.diagnostics for structured errors."
            }
        case .diagnostics:
            guard let textEditor, textEditor.language == .latex else {
                throw ToolExecutorError.invalidArguments(
                    "Open a LaTeX source file before reading diagnostics"
                )
            }
            return textEditor.toolDiagnosticReport()
        case .export(let rawFormat, let rawDestination):
            guard let textEditor else { throw ToolExecutorError.textUnavailable }
            guard rawDestination.hasPrefix("/") else {
                throw ToolExecutorError.invalidArguments(
                    "destination must be an absolute file path")
            }
            let url = URL(fileURLWithPath: rawDestination).standardizedFileURL
            let data = try await exportedTextData(
                format: rawFormat,
                editor: textEditor
            )
            try await Task.detached(priority: .userInitiated) {
                let parent = url.deletingLastPathComponent()
                var isDirectory: ObjCBool = false
                guard
                    FileManager.default.fileExists(
                        atPath: parent.path,
                        isDirectory: &isDirectory
                    ), isDirectory.boolValue
                else {
                    throw ToolExecutorError.invalidArguments(
                        "The destination folder does not exist"
                    )
                }
                try data.write(to: url, options: .atomic)
            }.value
            return "Exported \(url.lastPathComponent) to \(url.path)."
        }
    }

    private func validatedTextFileName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
            !name.contains("/"), !name.contains(":"), !name.contains("\0")
        else {
            throw ToolExecutorError.invalidArguments(
                "name must be a safe filename without path separators"
            )
        }
        return name
    }

    private func normalizedLanguage(_ value: String) -> LanguageID {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["plain", "plaintext", "plain_text", "txt", "text"].contains(normalized) {
            return .plainText
        }
        return LanguageID(rawValue: normalized)
    }

    private func exportedTextData(
        format rawFormat: String,
        editor: TextEditorViewModel
    ) async throws -> Data {
        let format = rawFormat.lowercased().filter(\.isLetter)
        if ["text", "txt", "plaintext", "source"].contains(format) {
            return Data(editor.text.utf8)
        }
        guard ["html", "rtf", "richtext"].contains(format) else {
            throw ToolExecutorError.invalidArguments(
                "format must be html, rtf, or plain text; use convert.run for PDF or DOCX"
            )
        }
        let source = editor.text
        let highlighted = await SyntaxHighlighter().highlights(
            in: source,
            language: editor.language,
            visibleRange: NSRange(location: 0, length: (source as NSString).length)
        )
        let attributed = TextSnippetOperations.attributedString(
            source: source,
            tokens: highlighted.tokens
        )
        if format == "html" {
            let html = TextSnippetOperations.standaloneHTML(
                title: editor.activeFile?.relativePath ?? "Untitled",
                attributedString: attributed
            )
            return Data(html.utf8)
        }
        guard
            let data = TextSnippetOperations.richTextData(
                from: attributed,
                backgroundColor: .white
            )
        else {
            throw ToolExecutorError.invalidArguments("The active file is empty")
        }
        return data
    }

    public func openEditor(for assetID: AssetID, initialTime: RationalTime? = nil) {
        guard editor == nil, imageEditor == nil, pdfEditor == nil, textEditor == nil,
            let asset = assets.first(where: { $0.id == assetID && $0.kind == .video }),
            let duration = asset.duration,
            let runtime
        else { return }
        let now = Date()
        let item = TimelineItem(
            id: .generate(),
            assetID: asset.id,
            sourceRange: TimeRange(start: .zero, duration: duration)
        )
        do {
            let document = try ProjectDocument(
                id: .generate(),
                name: URL(fileURLWithPath: asset.displayName)
                    .deletingPathExtension().lastPathComponent,
                timeline: Timeline(video: [item]),
                createdAt: now,
                modifiedAt: now
            )
            let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            let editor = EditorViewModel(
                document: document,
                assets: assetMap,
                clickTrackingState: clickTrackingState,
                resolving: { id in try await runtime.url(for: id) },
                persisting: { document, inverse in
                    try await runtime.saveProject(document)
                    if let inverse {
                        try await runtime.appendHistory(inverse, project: document.id)
                    }
                }
            )
            self.editor = editor
            selectedWorkspace = .video
            if let initialTime { editor.seek(to: initialTime) }
            Task {
                do {
                    try await runtime.saveProject(document)
                    let tracks = await runtime.eventTracks(for: Array(assetMap.keys))
                    editor.setEventTracks(tracks)
                    editor.start()
                } catch {
                    lastMessage = "The project could not be created."
                    self.editor = nil
                }
            }
        } catch {
            lastMessage = "The selected clip could not be opened."
        }
    }

    private func createEmptyVideoEditor() {
        guard editor == nil, imageEditor == nil, pdfEditor == nil, textEditor == nil else {
            return
        }
        guard let runtime else {
            selectedWorkspace = .video
            lastMessage = "The library is still opening. Try again in a moment."
            return
        }
        let now = Date()
        do {
            let document = try ProjectDocument(
                id: .generate(),
                name: "Untitled Project",
                createdAt: now,
                modifiedAt: now
            )
            let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            let editor = EditorViewModel(
                document: document,
                assets: assetMap,
                clickTrackingState: clickTrackingState,
                resolving: { id in try await runtime.url(for: id) },
                persisting: { document, inverse in
                    try await runtime.saveProject(document)
                    if let inverse {
                        try await runtime.appendHistory(inverse, project: document.id)
                    }
                }
            )
            self.editor = editor
            selectedWorkspace = .video
            selection.deselectAll()
            Task {
                do {
                    try await runtime.saveProject(document)
                } catch {
                    guard self.editor === editor else { return }
                    lastMessage = "The empty project could not be created."
                    self.editor = nil
                }
            }
        } catch {
            lastMessage = "The empty project could not be created."
        }
    }

    public func closeEditor() {
        editor?.stop()
        editor = nil
    }

    public func openImageEditor(
        for assetID: AssetID,
        initialTool: ImageEditorTool = .select
    ) {
        guard imageEditor == nil, editor == nil, pdfEditor == nil, textEditor == nil,
            let asset = assets.first(where: { $0.id == assetID && $0.kind == .image }),
            let runtime
        else { return }
        Task {
            do {
                let sourceURL = try await runtime.url(for: assetID)
                let width = max(asset.width ?? 1_920, 1)
                let height = max(asset.height ?? 1_080, 1)
                let document =
                    try await runtime.imageDocument(for: assetID)
                    ?? ImageDocument(
                        sourceAssetID: assetID,
                        canvas: ImageCanvas(width: width, height: height)
                    )
                let imageEditor = ImageEditorViewModel(
                    document: document,
                    sourceURL: sourceURL,
                    sourceCanvas: ImageCanvas(width: width, height: height),
                    persisting: { document in
                        try await runtime.saveImageDocument(document)
                    }
                )
                self.imageEditor = imageEditor
                selectedWorkspace = .photo
                try await runtime.saveImageDocument(document)
                imageEditor.start()
                imageEditor.activate(initialTool)
            } catch {
                lastMessage = "The selected image could not be opened."
            }
        }
    }

    public func closeImageEditor() {
        imageEditor?.stop()
        imageEditor = nil
    }

    public func openPDFEditor(for assetID: AssetID) {
        guard pdfEditor == nil, editor == nil, imageEditor == nil, textEditor == nil,
            let asset = assets.first(where: { $0.id == assetID && $0.kind == .document }),
            let runtime
        else { return }
        Task {
            do {
                let sourceURL = try await runtime.url(for: assetID)
                let source = try PDFiumDocument(url: sourceURL)
                let title = URL(fileURLWithPath: asset.displayName)
                    .deletingPathExtension().lastPathComponent
                let document =
                    try await runtime.pdfDocument(for: assetID)
                    ?? source.makeEditDocument(sourceAssetID: assetID, title: title)
                let pdfEditor = PDFEditorViewModel(
                    document: document,
                    sourceURL: sourceURL,
                    source: source,
                    fontStore: PDFOpenFontStore(cacheDirectory: pdfFontCacheURL),
                    automaticallyResolveMissingFonts: isPDFFontAutoDownloadEnabled,
                    persisting: { document in
                        try await runtime.savePDFDocument(document)
                    }
                )
                self.pdfEditor = pdfEditor
                selectedWorkspace = .pdf
                try await runtime.savePDFDocument(document)
                pdfEditor.start()
            } catch {
                lastMessage = "The selected PDF could not be opened."
            }
        }
    }

    public func closePDFEditor() {
        pdfEditor?.stop()
        pdfEditor = nil
    }

    public func openTextEditor(for assetID: AssetID) {
        guard textEditor == nil, editor == nil, imageEditor == nil, pdfEditor == nil,
            let asset = assets.first(where: { $0.id == assetID && $0.kind == .text }),
            let runtime
        else { return }
        Task {
            do {
                let sourceURL = try await runtime.url(for: assetID)
                if ["tex", "latex", "sty", "cls", "bib"].contains(
                    sourceURL.pathExtension.lowercased()
                ) {
                    try await openTeXProjectEditor(
                        sourceURL: sourceURL,
                        runtime: runtime
                    )
                    return
                }
                let loaded = try await runtime.loadTextContents(for: assetID)
                let document =
                    try await runtime.textDocument(for: assetID)
                    ?? TextDocument(
                        files: [
                            TextFile(
                                assetID: assetID,
                                relativePath: asset.displayName,
                                language: LanguageDetector.detect(
                                    path: asset.displayName,
                                    contents: loaded.text
                                ),
                                encoding: loaded.encoding,
                                lineEnding: loaded.lineEnding,
                                byteOrderMark: loaded.byteOrderMark
                            )
                        ]
                    )
                let textEditor = TextEditorViewModel(
                    document: document,
                    text: loaded.text,
                    sourceURL: sourceURL,
                    hashingWith: { SampledFileHasher.hash($0) },
                    persistingStructure: { document in
                        try await runtime.saveTextDocument(document, for: assetID)
                    },
                    persistingContents: { data, contentHash in
                        try await runtime.saveTextContents(
                            data,
                            for: assetID,
                            contentHash: contentHash
                        )
                    }
                )
                textEditor.configureTeXEngine(makeTeXEngine())
                self.textEditor = textEditor
                selectedWorkspace = .text
                try await runtime.saveTextDocument(document, for: assetID)
                textEditor.start()
            } catch let error as TextEngineError {
                switch error {
                case .binaryFile:
                    lastMessage = "This looks like a binary file, so Clip did not open it as text."
                case .tooLarge:
                    lastMessage = "This file is larger than 20 MB. Open it in an external editor."
                case .undecodable:
                    lastMessage = "Clip could not detect a supported text encoding."
                case .unreadable:
                    lastMessage = "The selected text file could not be read."
                case .unencodable, .invalidScratchBuffer:
                    lastMessage = "The selected text file could not be opened."
                }
            } catch {
                lastMessage = "The selected text file could not be opened."
            }
        }
    }

    private func openTeXProjectEditor(
        sourceURL: URL,
        runtime: AppRuntime
    ) async throws {
        let mediaRoot = LibraryLayout.media(in: libraryRoot)
        let project = try await Task.detached(priority: .userInitiated) {
            try TeXProjectFolderLoader.loadProject(
                containing: sourceURL,
                boundaryURL: mediaRoot
            )
        }.value
        let projectPath =
            project.rootURL == mediaRoot
            ? "" : String(project.rootURL.path.dropFirst(mediaRoot.path.count + 1))
        let projectFolder = projectPath.isEmpty ? "Media" : "Media/\(projectPath)"
        let persisted = try await runtime.texProjectDocument(for: projectFolder)
        let persistedFiles = Dictionary(
            uniqueKeysWithValues: (persisted?.files ?? []).map { ($0.relativePath, $0) }
        )
        let assetByPath = Dictionary(uniqueKeysWithValues: assets.map { ($0.relativePath, $0) })
        var files: [TextFile] = []
        var contents: [FileID: String] = [:]
        var sourceURLs: [FileID: URL] = [:]
        var backing: [FileID: (assetID: AssetID?, url: URL)] = [:]

        for relativePath in project.textFiles.keys.sorted(by: {
            $0.localizedStandardCompare($1) == .orderedAscending
        }) {
            guard let loaded = project.textFiles[relativePath],
                let fileURL = project.fileURLs[relativePath]
            else { continue }
            let libraryPath =
                projectFolder.isEmpty
                ? relativePath : "\(projectFolder)/\(relativePath)"
            let assetID = assetByPath[libraryPath]?.id
            var file = persistedFiles[relativePath] ?? TextFile(relativePath: relativePath)
            file.assetID = assetID
            file.relativePath = relativePath
            if !file.languageIsExplicit {
                file.language = LanguageDetector.detect(
                    path: relativePath,
                    contents: loaded.text
                )
            }
            file.encoding = loaded.encoding
            file.lineEnding = loaded.lineEnding
            file.byteOrderMark = loaded.byteOrderMark
            files.append(file)
            contents[file.id] = loaded.text
            sourceURLs[file.id] = fileURL
            backing[file.id] = (assetID, fileURL)
        }

        let selectedRelativePath = String(
            sourceURL.path.dropFirst(project.rootURL.path.count + 1)
        )
        let selectedID =
            files.first(where: { $0.relativePath == selectedRelativePath })?.id
            ?? files[0].id
        let sources = Dictionary(
            uniqueKeysWithValues: files.compactMap { file in
                contents[file.id].map { (file.relativePath, $0) }
            }
        )
        let persistedMainPath = persisted?.mainFileID.flatMap { id in
            persisted?.files.first(where: { $0.id == id })?.relativePath
        }
        let mainPath = TeXProjectAnalyzer.inferMainFile(
            sources: sources,
            selectedMainFile: persistedMainPath
        )
        let mainID = mainPath.flatMap { path in files.first(where: { $0.relativePath == path })?.id
        }
        let document = try TextDocument(
            id: persisted?.id ?? .generate(),
            files: files,
            mainFileID: mainID,
            settings: persisted?.settings ?? EditorSettings()
        )
        let projectBacking = backing
        let textEditor = TextEditorViewModel(
            document: document,
            contents: contents,
            activeFileID: selectedID,
            sourceURLs: sourceURLs,
            projectFileURLs: project.fileURLs,
            hashingWith: { SampledFileHasher.hash($0) },
            persistingStructure: { document in
                try await runtime.saveTeXProjectDocument(document, for: projectFolder)
            },
            persistingContents: { fileID, data, contentHash in
                guard let target = projectBacking[fileID] else { return }
                if let assetID = target.assetID {
                    try await runtime.saveTextContents(
                        data,
                        for: assetID,
                        contentHash: contentHash
                    )
                } else {
                    try await Task.detached(priority: .utility) {
                        try data.write(to: target.url, options: .atomic)
                    }.value
                }
            }
        )
        textEditor.configureTeXEngine(makeTeXEngine())
        self.textEditor = textEditor
        selectedWorkspace = .text
        try await runtime.saveTeXProjectDocument(document, for: projectFolder)
        textEditor.start()
    }

    /// Closes the current text editor and refreshes the scratch list.
    public func closeTextEditor() {
        if let textEditor, textEditor.hasExternalConflict {
            lastMessage = "Resolve the file change before closing the editor."
            return
        }
        if let textEditor, textEditor.isDetached, !textEditor.hasSavedDetachedCopy {
            lastMessage = "Save a copy of this detached buffer before closing."
            return
        }
        textEditor?.stop()
        textEditor = nil
        Task { await refreshScratchBuffers() }
    }

    /// Creates, persists, and opens a new unnamed text buffer.
    public func createScratchTextEditor() {
        guard textEditor == nil, editor == nil, imageEditor == nil, pdfEditor == nil,
            let runtime
        else { return }
        Task {
            do {
                let buffer = try await runtime.createScratchTextBuffer()
                openScratchTextEditor(buffer, runtime: runtime)
                await refreshScratchBuffers()
            } catch {
                lastMessage = "A new scratch buffer could not be created."
            }
        }
    }

    /// Restores and opens a previously persisted scratch buffer.
    public func openScratchTextEditor(_ id: DocumentID) {
        guard textEditor == nil, editor == nil, imageEditor == nil, pdfEditor == nil,
            let runtime
        else { return }
        Task {
            do {
                guard let buffer = try await runtime.scratchTextBuffer(id) else {
                    await refreshScratchBuffers()
                    lastMessage = "That scratch buffer is no longer available."
                    return
                }
                openScratchTextEditor(buffer, runtime: runtime)
            } catch {
                lastMessage = "That scratch buffer could not be opened."
            }
        }
    }

    private func closeOpenEditors() {
        closeEditor()
        closeImageEditor()
        closePDFEditor()
        closeTextEditor()
    }

    private func refreshAssets() async {
        guard let runtime else { return }
        assetRefreshGeneration &+= 1
        let generation = assetRefreshGeneration
        do {
            let snapshot = try await runtime.assets()
            guard generation == assetRefreshGeneration else { return }
            assets = snapshot
            await refreshFolderTree()
        } catch {
            guard generation == assetRefreshGeneration else { return }
            lastMessage = "The library index could not be read. Reopen Clip to rebuild it."
        }
    }

    private func refreshScratchBuffers() async {
        guard let runtime else { return }
        do {
            scratchBuffers = try await runtime.scratchTextRecords()
        } catch {
            scratchBuffers = []
            lastMessage = "Scratch buffers could not be restored."
        }
    }

    private func openScratchTextEditor(
        _ buffer: ScratchTextBuffer,
        runtime: AppRuntime
    ) {
        let documentID = buffer.document.id
        let textEditor = TextEditorViewModel(
            document: buffer.document,
            text: buffer.contents.text,
            sourceURL: nil,
            hashingWith: { SampledFileHasher.hash($0) },
            persistingStructure: { document in
                try await runtime.saveScratchTextDocument(document)
            },
            persistingContents: { data, _ in
                try await runtime.saveScratchTextContents(data, for: documentID)
            }
        )
        textEditor.configureTeXEngine(makeTeXEngine())
        self.textEditor = textEditor
        selectedWorkspace = .text
        textEditor.start()
    }

    private func makeTeXEngine() -> any TeXEngine {
        let ledger = aiSettings.ledger
        let tectonic = TectonicEngine(
            cacheDirectory: LibraryLayout.texCache(in: libraryRoot),
            networkAccessObserver: {
                await ledger.record(
                    EgressEntry(
                        provider: .tectonic,
                        model: TectonicEngine.version,
                        purpose: .texPackage,
                        mediaAttached: false
                    )
                )
            }
        )
        #if DIRECT_BUILD
            return BibliographyRoutingTeXEngine(
                primary: tectonic,
                biberEngine: SystemTeXEngine(isEnabled: true)
            )
        #else
            return BibliographyRoutingTeXEngine(primary: tectonic)
        #endif
    }

    /// Clears cached TeX packages without touching source files or compiled PDFs.
    public func clearTeXPackageCache() {
        let cache = texPackageCacheURL
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: cache.path) {
                        try manager.removeItem(at: cache)
                    }
                    try manager.createDirectory(at: cache, withIntermediateDirectories: true)
                }.value
                self?.lastMessage = "The TeX package cache was cleared."
            } catch {
                self?.lastMessage = "The TeX package cache could not be cleared."
            }
        }
    }

    /// Clears downloaded open fonts without touching PDF files or edit documents.
    public func clearPDFFontCache() {
        let cache = pdfFontCacheURL
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: cache.path) {
                        try manager.removeItem(at: cache)
                    }
                    try manager.createDirectory(at: cache, withIntermediateDirectories: true)
                }.value
                self?.lastMessage = "The PDF font cache was cleared."
            } catch {
                self?.lastMessage = "The PDF font cache could not be cleared."
            }
        }
    }

    private func refreshFolderTree() async {
        guard let runtime else { return }
        folderTree = try? await runtime.folderTree(expanding: expandedFolders)
        folderDestinations = [""] + ((try? await runtime.folderDestinations()) ?? ["Inbox"])
    }

    /// AppModel mutations finish in asynchronous tasks, after AppKit's event
    /// group has closed. Because automatic grouping is disabled, every such
    /// registration must establish an explicit boundary or NSUndoManager raises
    /// an internal inconsistency exception after the operation succeeds.
    private func registerUndo(
        on manager: UndoManager? = nil,
        actionName: String,
        action: @escaping (AppModel) -> Void
    ) {
        let undoManager = manager ?? self.undoManager
        let opensGroup = undoManager.groupingLevel == 0
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: action)
        undoManager.setActionName(actionName)
        if opensGroup { undoManager.endUndoGrouping() }
    }

    private func restoreFolder(_ receipt: FolderTrashReceipt) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.restoreFolder(receipt)
                await refreshAssets()
                registerUndo(actionName: "Move Folder to Trash") { target in
                    let path = receipt.originalURL.path
                        .replacingOccurrences(
                            of: LibraryLayout.media(in: target.libraryRoot).path + "/", with: "")
                    target.trashFolder(path)
                }
            } catch {
                lastMessage = "The folder could not be restored."
            }
        }
    }

    private func assetOrdering(_ lhs: AssetRecord, _ rhs: AssetRecord) -> Bool {
        switch assetSort {
        case .name:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        case .kind:
            return lhs.kind.rawValue == rhs.kind.rawValue
                ? lhs.displayName < rhs.displayName : lhs.kind.rawValue < rhs.kind.rawValue
        case .duration:
            return (lhs.duration?.seconds ?? 0) > (rhs.duration?.seconds ?? 0)
        case .size:
            return lhs.byteSize > rhs.byteSize
        case .modified:
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func performTrash(_ ids: [AssetID]) async {
        guard let runtime, !ids.isEmpty else { return }
        do {
            let receipt = try await runtime.trash(assetIDs: ids)
            selection.deselectAll()
            await refreshAssets()
            registerUndo(actionName: "Move to Trash") { target in
                Task { await target.restoreFromTrash(receipt) }
            }
            lastMessage = ids.count == 1 ? "Moved to Trash" : "Moved \(ids.count) items to Trash"
        } catch {
            lastMessage = "Clip couldn't move the selected files to Trash."
        }
    }

    private func restoreFromTrash(_ receipt: TrashReceipt) async {
        guard let runtime else { return }
        do {
            try await runtime.restore(receipt)
            await refreshAssets()
            let ids = receipt.items.map { $0.asset.id }
            selection.setItems(assets.map(\.id))
            for id in ids {
                selection.click(id, modifiers: selection.selected.isEmpty ? [] : [.command])
            }
            registerUndo(actionName: "Move to Trash") { target in
                Task { await target.performTrash(ids) }
            }
            lastMessage = ids.count == 1 ? "Restored from Trash" : "Restored \(ids.count) items"
        } catch {
            lastMessage = "Clip couldn't restore the files. They may have been removed from Trash."
        }
    }

    private func resolvedConversionOutput(
        for item: ConversionQueueItem,
        index: Int,
        reserved: inout Set<URL>
    ) throws -> URL? {
        let preset =
            ConversionPreset.builtIns.first { $0.id == item.selectedPresetID }?.name
            ?? item.target.displayName
        let resolution: String
        if let width = item.asset.width, let height = item.asset.height {
            resolution = "\(width)x\(height)"
        } else {
            resolution = "source"
        }
        let proposed = try conversionDestination.resolve(
            in: conversionDestinationFolder,
            context: ExportTemplateContext(
                project: item.inputURL.deletingPathExtension().lastPathComponent,
                preset: preset,
                codec: item.target.formatID.codec ?? item.target.fileExtension,
                resolution: resolution,
                duration: item.asset.duration.map { String(format: "%.1f", $0.seconds) } ?? "0",
                index: index
            ),
            extension: item.target.fileExtension
        )
        switch conversionConflictPolicy {
        case .rename:
            return uniqueOutputURL(proposed: proposed, reserved: &reserved)
        case .overwrite:
            guard reserved.insert(proposed).inserted else {
                throw ExportDestinationError.conflictingBatchOutput
            }
            return proposed
        case .skip:
            guard !FileManager.default.fileExists(atPath: proposed.path),
                reserved.insert(proposed).inserted
            else { return nil }
            return proposed
        }
    }

    private func performConversionCompletionAction(for outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        switch conversionDestination.onCompletion {
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                outputs.map(\.path).joined(separator: "\n"),
                forType: .string
            )
        case .nothing:
            break
        }
    }

    private func uniqueOutputURL(
        proposed: URL,
        reserved: inout Set<URL>
    ) -> URL {
        if !FileManager.default.fileExists(atPath: proposed.path),
            reserved.insert(proposed).inserted
        {
            return proposed
        }
        let stem = proposed.deletingPathExtension().lastPathComponent
        let pathExtension = proposed.pathExtension
        var suffix = 2
        while true {
            let candidate = proposed.deletingLastPathComponent().appendingPathComponent(
                "\(stem)-\(suffix).\(pathExtension)"
            )
            if !FileManager.default.fileExists(atPath: candidate.path),
                reserved.insert(candidate).inserted
            {
                return candidate
            }
            suffix += 1
        }
    }
}

/// Identity target for one file rename's complete undo/redo chain.
///
/// `UndoManager` can remove actions by target but not by individual closure, so
/// each asynchronous filesystem rename owns a distinct token. If a later undo
/// fails, only that rename chain is discarded.
private final class AssetRenameUndoToken {
    weak var manager: UndoManager?

    init(manager: UndoManager) {
        self.manager = manager
    }
}

extension String {
    fileprivate var deletingLastPathComponent: String {
        (self as NSString).deletingLastPathComponent
    }

    fileprivate var deletingMediaPrefix: String {
        hasPrefix("Media/") ? String(dropFirst("Media/".count)) : self
    }
}

public struct TrashConfirmation: Identifiable, Sendable {
    public let id = UUID()
    public var assetIDs: [AssetID]
    public var projectNames: [String]

    public init(assetIDs: [AssetID], projectNames: [String]) {
        self.assetIDs = assetIDs
        self.projectNames = projectNames
    }
}
