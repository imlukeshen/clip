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
    public private(set) var folderTree: FolderNode?
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
    public var isCaptureHistoryPresented = false
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

    private let shortcutReader: ShortcutReader
    private var runtime: AppRuntime?
    private var libraryChangesTask: Task<Void, Never>?
    private var indexProgressTask: Task<Void, Never>?
    private var indexActivityTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var conversionTask: Task<Void, Never>?
    private var hasStarted = false
    private var folderBackHistory: [String?] = []
    private var folderForwardHistory: [String?] = []

    public init(
        libraryRoot: URL = AppModel.defaultLibraryRoot,
        shortcutReader: ShortcutReader = ShortcutReader()
    ) {
        let normalizedLibraryRoot = libraryRoot.standardizedFileURL
        self.libraryRoot = normalizedLibraryRoot
        self.shortcutReader = shortcutReader
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

    /// Decides what happens to a file macOS just wrote for a screenshot or
    /// recording.
    ///
    /// A recording lands in the timeline if one is open, because that is what
    /// you were about to do with it anyway. Everything else is staged in the
    /// history, where it expires — the library only gains an asset when you
    /// explicitly save one.
    private func handleSystemCapture(_ url: URL) async {
        guard let runtime else { return }
        let isVideo = CaptureHistoryItem.kind(forPathExtension: url.pathExtension) == .video
        if isVideo, editor != nil, imageEditor == nil, pdfEditor == nil, textEditor == nil {
            do {
                let record = try await runtime.ingest(url, source: .inbox)
                await refreshAssets()
                await handleAutomaticIngest(record)
                return
            } catch {
                lastMessage = "That recording could not be opened in the timeline."
                return
            }
        }
        guard !isVideo || captureDestination == .clipboard else { return }
        do {
            let item = try await runtime.stageCapture(url)
            await runtime.writeToPasteboard(item)
            await refreshCaptureHistory()
            lastMessage = "Copied to the clipboard."
        } catch {
            // A format the history cannot hold is not worth interrupting for;
            // the file is still exactly where the system put it.
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

    /// Puts an entry on the system pasteboard so it can be pasted in any app.
    public func copyCaptureToPasteboard(_ item: CaptureHistoryItem) {
        Task { await runtime?.writeToPasteboard(item) }
        lastMessage = "Copied \(item.displayName)."
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
                undoManager.registerUndo(withTarget: self) { target in
                    target.trashFolder(path)
                }
                undoManager.setActionName("Create Folder")
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
                undoManager.registerUndo(withTarget: self) { target in
                    target.renameFolder(updated, to: oldName)
                }
                undoManager.setActionName("Rename Folder")
            } catch {
                lastMessage = "The folder could not be renamed."
            }
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
                undoManager.registerUndo(withTarget: self) { target in
                    for (parent, ids) in oldParents {
                        target.moveAssets(ids, to: parent)
                    }
                }
                undoManager.setActionName("Move Assets")
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
                undoManager.registerUndo(withTarget: self) { target in
                    target.moveFolder(updated, to: oldParent)
                }
                undoManager.setActionName("Move Folder")
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
                undoManager.registerUndo(withTarget: self) { target in
                    target.restoreFolder(receipt)
                }
                undoManager.setActionName("Move Folder to Trash")
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
        switch AssetActivationRoute(kind: asset.kind) {
        case .videoEditor: openEditor(for: id)
        case .photoEditor: openImageEditor(for: id)
        case .pdfEditor: openPDFEditor(for: id)
        case .textEditor: openTextEditor(for: id)
        case .none:
            showWorkspace(.convert)
            lastMessage = "Audio files are available in Convert."
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
                        var item = ConversionQueueItem(asset: asset, inputURL: inputURL)
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
        guard !prompt.isEmpty, !isAssistantWorking, let editor, let runtime else { return }
        assistantDraft = ""
        assistantMessages.append(AssistantMessage(role: .user, text: prompt))
        isAssistantWorking = true
        let turnID = UUID().uuidString.lowercased()
        let digest = editor.assistantContextDigest()
        let context = assistantToolContext(editor: editor, runtime: runtime)
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
                    } else {
                        try editor.perform(combinedPatch)
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
        guard let invocation = action.invocation, let editor, let runtime,
            !isAssistantWorking
        else { return }
        isAssistantWorking = true
        let context = assistantToolContext(editor: editor, runtime: runtime)
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
        return context
    }

    private func supportsAssistantConfirmation(_ invocation: ToolInvocation) -> Bool {
        if invocation.name == "convert.run" { return true }
        guard invocation.name == "runCommand",
            case .object(let fields) = invocation.arguments,
            fields["id"] == .string("convert.run")
        else { return false }
        return true
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
                    sourceURL: try await runtime.url(for: assetID),
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
        do {
            assets = try await runtime.assets()
            await refreshFolderTree()
        } catch {
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
        self.textEditor = textEditor
        selectedWorkspace = .text
        textEditor.start()
    }

    private func refreshFolderTree() async {
        guard let runtime else { return }
        folderTree = try? await runtime.folderTree(expanding: expandedFolders)
    }

    private func restoreFolder(_ receipt: FolderTrashReceipt) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.restoreFolder(receipt)
                await refreshAssets()
                undoManager.registerUndo(withTarget: self) { target in
                    let path = receipt.originalURL.path
                        .replacingOccurrences(
                            of: LibraryLayout.media(in: target.libraryRoot).path + "/", with: "")
                    target.trashFolder(path)
                }
                undoManager.setActionName("Move Folder to Trash")
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
            undoManager.registerUndo(withTarget: self) { target in
                Task { await target.restoreFromTrash(receipt) }
            }
            undoManager.setActionName("Move to Trash")
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
            undoManager.registerUndo(withTarget: self) { target in
                Task { await target.performTrash(ids) }
            }
            undoManager.setActionName("Move to Trash")
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
