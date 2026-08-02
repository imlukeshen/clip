import AIKit
import CaptureKit
import ConvertKit
import CoreModel
import Foundation
import LibraryStore
import Observation

@MainActor
@Observable
public final class AppModel {
    public var selectedWorkspace: Workspace = .inbox
    public var searchQuery = ""
    public private(set) var assets: [AssetRecord] = []
    public private(set) var folderTree: FolderNode?
    public private(set) var expandedFolders: Set<String>
    public var selectedFolderPath: String? = "Inbox"
    public var browserViewMode: BrowserViewMode = .grid
    public var assetSort: AssetSort = .modified
    public var isInspectorVisible = true
    public var isCommandPalettePresented = false
    public var commandQuery = ""
    public private(set) var shortcutRow: ShortcutRowModel
    public private(set) var libraryRoot: URL
    public private(set) var isWatching = false
    public private(set) var ingestCount = 0
    public private(set) var conversionQueue: [ConversionQueueItem] = []
    public private(set) var editor: EditorViewModel?
    public private(set) var lastMessage: String?
    public private(set) var clickTrackingState: ClickTrackingState = .checking
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
    private var hasStarted = false
    private var folderBackHistory: [String?] = []
    private var folderForwardHistory: [String?] = []

    public init(
        libraryRoot: URL = AppModel.defaultLibraryRoot,
        shortcutReader: ShortcutReader = ShortcutReader()
    ) {
        self.libraryRoot = libraryRoot.standardizedFileURL
        self.shortcutReader = shortcutReader
        self.shortcutRow = ShortcutRowModel(result: shortcutReader.read())
        self.aiSettings = AISettingsModel(libraryRoot: libraryRoot.standardizedFileURL)
        self.expandedFolders = Set(
            UserDefaults.standard.stringArray(forKey: "reel.expandedFolders") ?? [""]
        )
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
        return movies.appendingPathComponent("Reel", isDirectory: true)
    }

    public static var sandboxLibraryRoot: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Reel", isDirectory: true)
    }

    public var visibleAssets: [AssetRecord] {
        let scoped: [AssetRecord]
        if selectedWorkspace == .inbox, let selectedFolderPath {
            let prefix = selectedFolderPath.isEmpty
                ? "Media/" : "Media/\(selectedFolderPath)/"
            scoped = assets.filter { asset in
                guard asset.relativePath.hasPrefix(prefix) else { return false }
                return !asset.relativePath.dropFirst(prefix.count).contains("/")
            }
        } else {
            scoped = assets
        }
        let searched = searchQuery.isEmpty ? scoped : scoped.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchQuery)
        }
        return searched.sorted(by: assetOrdering)
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
        case .convert: conversionQueue.count
        }
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        refreshShortcuts()
        do {
            let runtime = try await AppRuntime(libraryRoot: libraryRoot)
            self.runtime = runtime
            let changes = await runtime.changes()
            libraryChangesTask = Task { [weak self] in
                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    await self?.refreshAssets()
                }
            }
            try await runtime.start()
            isWatching = true
            canRevertMigration = LibraryMigration.canRevert(at: libraryRoot)
            clickTrackingState = await runtime.clickTrackingState()
            await refreshAssets()
        } catch AppRuntimeError.migrationRequired(let plan) {
            isWatching = false
            pendingMigrationPlan = plan
        } catch {
            isWatching = false
            lastMessage = "The library could not be opened. Check the folder and try again."
        }
    }

    public func selectFolder(_ path: String?) {
        guard selectedFolderPath != path || selectedWorkspace != .inbox else { return }
        folderBackHistory.append(selectedFolderPath)
        folderForwardHistory.removeAll()
        selectedWorkspace = .inbox
        selectedFolderPath = path
        selection.deselectAll()
    }

    public func navigateBack() {
        guard let destination = folderBackHistory.popLast() else { return }
        folderForwardHistory.append(selectedFolderPath)
        selectedFolderPath = destination
        selectedWorkspace = .inbox
        selection.deselectAll()
    }

    public func navigateForward() {
        guard let destination = folderForwardHistory.popLast() else { return }
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
        guard let editor else {
            lastMessage = "Open a project to run \(CommandRegistry.command(id: id)?.title ?? id.rawValue)."
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
        lastMessage = "The library was left unchanged. Reopen Reel when you're ready to upgrade."
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
                lastMessage = "Migration reverted. Quit Reel before opening this library with v1."
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

    public func accept(_ urls: [URL], source: IngestSource) {
        guard !urls.isEmpty else { return }
        selectedWorkspace = WorkspaceRouter.destination(for: urls[0])
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
                lastMessage = "Reel couldn't check whether those files are in a project."
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
            case .waiting, .failed:
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
        selectedWorkspace = .convert
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
                        conversionQueue.append(
                            ConversionQueueItem(asset: asset, inputURL: inputURL)
                        )
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

    public func removeConversion(_ id: UUID) {
        guard let item = conversionQueue.first(where: { $0.id == id }) else { return }
        if case .converting = item.status { return }
        conversionQueue.removeAll { $0.id == id }
    }

    public func convertQueuedItems() {
        guard !isConverting, let runtime else { return }

        var jobs: [(ConversionPlan, URL, URL)] = []
        var jobItems: [(id: UUID, output: URL)] = []
        var reservedOutputs: Set<URL> = []
        let exportFolder = libraryRoot.appendingPathComponent("Exports", isDirectory: true)

        for index in conversionQueue.indices {
            switch conversionQueue[index].status {
            case .waiting, .failed:
                break
            case .converting, .completed:
                continue
            }
            if case .unsupported(let reason) = conversionQueue[index].plan.backend {
                conversionQueue[index].status = .failed(reason)
                continue
            }
            let item = conversionQueue[index]
            let output = uniqueOutputURL(
                folder: exportFolder,
                filename: item.outputFilename,
                reserved: &reservedOutputs
            )
            conversionQueue[index].progress = 0
            conversionQueue[index].status = .converting
            jobs.append((item.plan, item.inputURL, output))
            jobItems.append((item.id, output))
        }
        guard !jobs.isEmpty else { return }

        Task {
            do {
                let stream = await runtime.convert(jobs, concurrency: 2)
                var completedCount = 0
                for try await update in stream {
                    guard jobItems.indices.contains(update.itemIndex),
                        let queueIndex = conversionQueue.firstIndex(
                            where: { $0.id == jobItems[update.itemIndex].id }
                        )
                    else { continue }
                    conversionQueue[queueIndex].progress = update.itemProgress
                    if update.completed > completedCount {
                        completedCount = update.completed
                        conversionQueue[queueIndex].status = .completed(
                            jobItems[update.itemIndex].output
                        )
                    }
                }
                lastMessage =
                    "Converted \(completedCount) file\(completedCount == 1 ? "" : "s") to Exports."
            } catch {
                for item in jobItems {
                    guard let index = conversionQueue.firstIndex(where: { $0.id == item.id }) else {
                        continue
                    }
                    if case .converting = conversionQueue[index].status {
                        conversionQueue[index].status = .failed(error.localizedDescription)
                    }
                }
                lastMessage = "One or more conversions couldn't be completed."
            }
        }
    }

    public func clearMessage() {
        lastMessage = nil
    }

    public func sendAssistantMessage() {
        let prompt = assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isAssistantWorking, let editor else { return }
        assistantDraft = ""
        assistantMessages.append(AssistantMessage(role: .user, text: prompt))
        isAssistantWorking = true
        let turnID = UUID().uuidString.lowercased()
        let digest = editor.assistantContextDigest()
        let context = editor.toolExecutionContext()
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
        guard let index = pendingAssistantActions.firstIndex(where: { $0.id == id }),
            let patch = pendingAssistantActions[index].result.patch,
            let editor
        else { return }
        do {
            try editor.perform(patch)
            assistantMessages.append(
                AssistantMessage(
                    role: .status, text: pendingAssistantActions[index].result.message))
            pendingAssistantActions.remove(at: index)
        } catch {
            assistantMessages.append(
                AssistantMessage(role: .status, text: error.localizedDescription))
        }
    }

    public func rejectAssistantAction(_ id: String) {
        pendingAssistantActions.removeAll { $0.id == id }
        assistantMessages.append(AssistantMessage(role: .status, text: "Edit skipped."))
    }

    public func openEditor(for assetID: AssetID) {
        guard editor == nil,
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

    private func refreshAssets() async {
        guard let runtime else { return }
        do {
            assets = try await runtime.assets()
            await refreshFolderTree()
        } catch {
            lastMessage = "The library index could not be read. Reopen Reel to rebuild it."
        }
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
                        .replacingOccurrences(of: LibraryLayout.media(in: target.libraryRoot).path + "/", with: "")
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
            lastMessage = "Reel couldn't move the selected files to Trash."
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
            lastMessage = "Reel couldn't restore the files. They may have been removed from Trash."
        }
    }

    private func uniqueOutputURL(
        folder: URL,
        filename: String,
        reserved: inout Set<URL>
    ) -> URL {
        let proposed = folder.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: proposed.path),
            reserved.insert(proposed).inserted
        {
            return proposed
        }
        let stem = proposed.deletingPathExtension().lastPathComponent
        let pathExtension = proposed.pathExtension
        var suffix = 2
        while true {
            let candidate = folder.appendingPathComponent(
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
