import CaptureKit
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
        case .convert: ingestCount
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

    public func clearMessage() {
        lastMessage = nil
    }

    private func refreshAssets() async {
        guard let runtime else { return }
        do {
            assets = try await runtime.assets()
        } catch {
            lastMessage = "The library index could not be read. Reopen Reel to rebuild it."
        }
    }
}
