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
    public private(set) var shortcutRow: ShortcutRowModel
    public private(set) var libraryRoot: URL
    public private(set) var isWatching = false
    public private(set) var ingestCount = 0
    public private(set) var conversionQueue: [ConversionQueueItem] = []
    public private(set) var editor: EditorViewModel?
    public private(set) var lastMessage: String?
    public var selectedAssetID: String?

    private let shortcutReader: ShortcutReader
    private var runtime: AppRuntime?
    private var libraryChangesTask: Task<Void, Never>?
    private var hasStarted = false

    public init(
        libraryRoot: URL = AppModel.defaultLibraryRoot,
        shortcutReader: ShortcutReader = ShortcutReader()
    ) {
        self.libraryRoot = libraryRoot.standardizedFileURL
        self.shortcutReader = shortcutReader
        self.shortcutRow = ShortcutRowModel(result: shortcutReader.read())
    }

    public static var defaultLibraryRoot: URL {
        let movies =
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return movies.appendingPathComponent("Reel", isDirectory: true)
    }

    public var visibleAssets: [AssetRecord] {
        guard !searchQuery.isEmpty else { return assets }
        return assets.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

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
            await refreshAssets()
        } catch {
            isWatching = false
            lastMessage = "The library could not be opened. Check the folder and try again."
        }
    }

    public func refreshShortcuts() {
        shortcutRow = ShortcutRowModel(result: shortcutReader.read())
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
        } catch {
            lastMessage = "The library index could not be read. Reopen Reel to rebuild it."
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
