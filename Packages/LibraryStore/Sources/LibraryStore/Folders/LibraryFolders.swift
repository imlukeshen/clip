import CoreModel
import Foundation

public actor LibraryFolders {
    private let root: URL
    private let media: URL
    private let library: LibraryStore
    private let trashManager: any FileTrashManaging

    public init(
        root: URL,
        library: LibraryStore,
        trashManager: any FileTrashManaging = SystemTrashManager()
    ) {
        self.root = root.standardizedFileURL
        self.media = LibraryLayout.media(in: root.standardizedFileURL)
        self.library = library
        self.trashManager = trashManager
    }

    public func tree(expanding: Set<String>) async throws -> FolderNode {
        let assets = try await library.assets(kind: nil, limit: Int.max, offset: 0)
        return try node(relativePath: "", expanding: expanding, assets: assets, forceLoad: true)
    }

    @discardableResult
    public func createFolder(named name: String, in relativePath: String) async throws -> String {
        try validateName(name)
        let parent = try folderURL(relativePath)
        let destination = uniqueFolderURL(named: name, in: parent)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return relative(destination)
    }

    @discardableResult
    public func rename(_ relativePath: String, to name: String) async throws -> String {
        try validateMutableFolder(relativePath)
        try validateName(name)
        let source = try folderURL(relativePath)
        let destination = uniqueFolderURL(named: name, in: source.deletingLastPathComponent())
        return try await relocateFolder(source: source, destination: destination)
    }

    @discardableResult
    public func move(_ assetIDs: [AssetID], to relativePath: String) async throws
        -> [AssetRecord]
    {
        let destinationFolder = try folderURL(relativePath)
        var updated: [AssetRecord] = []
        var moves: [(URL, URL)] = []
        do {
            for id in Array(Set(assetIDs)) {
                guard var asset = try await library.asset(id: id) else {
                    throw LibraryError.assetNotFound(id)
                }
                let source = root.appendingPathComponent(asset.relativePath)
                let destination = uniqueFileURL(named: source.lastPathComponent, in: destinationFolder)
                guard source.standardizedFileURL != destination.standardizedFileURL else {
                    updated.append(asset)
                    continue
                }
                try FileManager.default.moveItem(at: source, to: destination)
                moves.append((source, destination))
                asset.relativePath = "Media/\(relative(destination))"
                asset.displayName = destination.lastPathComponent

                if let eventPath = asset.eventTrackPath {
                    let eventSource = root.appendingPathComponent(eventPath)
                    if FileManager.default.fileExists(atPath: eventSource.path) {
                        let eventDestination = destination.deletingPathExtension()
                            .appendingPathExtension("events.json")
                        try FileManager.default.moveItem(at: eventSource, to: eventDestination)
                        moves.append((eventSource, eventDestination))
                        asset.eventTrackPath = "Media/\(relative(eventDestination))"
                    }
                }
                updated.append(asset)
            }
            try await library.updateLocations(updated)
            return updated
        } catch {
            rollback(moves)
            throw error
        }
    }

    @discardableResult
    public func moveFolder(_ from: String, to parent: String) async throws -> String {
        try validateMutableFolder(from)
        let source = try folderURL(from)
        let destinationParent = try folderURL(parent)
        guard !destinationParent.path.hasPrefix(source.path + "/") else {
            throw LibraryError.invalidRelativePath(parent)
        }
        let destination = uniqueFolderURL(named: source.lastPathComponent, in: destinationParent)
        return try await relocateFolder(source: source, destination: destination)
    }

    @discardableResult
    public func trash(_ assetIDs: [AssetID]) async throws -> TrashReceipt {
        try await library.trash(assetIDs: assetIDs)
    }

    @discardableResult
    public func trashFolder(_ relativePath: String) async throws -> FolderTrashReceipt {
        try validateMutableFolder(relativePath)
        let folder = try folderURL(relativePath)
        let prefix = "\(relative(folder))/"
        let assets = try await library.assets(kind: nil, limit: Int.max, offset: 0)
            .filter { $0.relativePath.hasPrefix("Media/\(prefix)") }
        let assetReceipt = try await library.trash(assetIDs: assets.map(\.id))
        do {
            let trashed = try trashManager.trashItem(at: folder)
            return FolderTrashReceipt(
                assets: assetReceipt,
                originalURL: folder,
                trashedURL: trashed
            )
        } catch {
            try? await library.restore(assetReceipt)
            throw error
        }
    }

    public func restoreFolder(_ receipt: FolderTrashReceipt) async throws {
        guard !FileManager.default.fileExists(atPath: receipt.originalURL.path) else {
            throw LibraryError.fileOperationFailed("restore folder destination exists")
        }
        try FileManager.default.createDirectory(
            at: receipt.originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: receipt.trashedURL, to: receipt.originalURL)
        try await library.restore(receipt.assets)
    }

    public func revealInFinder(_ assetIDs: [AssetID]) async {
        for id in assetIDs {
            guard let url = try? await library.url(for: id) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-R", url.path]
            try? process.run()
        }
    }

    private func node(
        relativePath: String,
        expanding: Set<String>,
        assets: [AssetRecord],
        forceLoad: Bool = false
    ) throws -> FolderNode {
        let url = try folderURL(relativePath)
        let directPrefix = relativePath.isEmpty ? "Media/" : "Media/\(relativePath)/"
        let count = assets.count { asset in
            let suffix = String(asset.relativePath.dropFirst(directPrefix.count))
            return asset.relativePath.hasPrefix(directPrefix) && !suffix.contains("/")
        }
        let shouldLoad = forceLoad || expanding.contains(relativePath)
        let children: [FolderNode]?
        if shouldLoad {
            children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { child in
                    let childPath = relative(child)
                    return try node(
                        relativePath: childPath,
                        expanding: expanding,
                        assets: assets
                    )
                }
        } else {
            children = nil
        }
        return FolderNode(
            id: relativePath,
            name: relativePath.isEmpty ? "Media" : url.lastPathComponent,
            children: children,
            assetCount: count
        )
    }

    private func relocateFolder(source: URL, destination: URL) async throws -> String {
        let sourcePath = relative(source)
        let destinationPath = relative(destination)
        let assets = try await library.assets(kind: nil, limit: Int.max, offset: 0)
        var updated: [AssetRecord] = []
        for var asset in assets where asset.relativePath.hasPrefix("Media/\(sourcePath)/") {
            let suffix = asset.relativePath.dropFirst("Media/\(sourcePath)".count)
            asset.relativePath = "Media/\(destinationPath)\(suffix)"
            if let event = asset.eventTrackPath, event.hasPrefix("Media/\(sourcePath)/") {
                let eventSuffix = event.dropFirst("Media/\(sourcePath)".count)
                asset.eventTrackPath = "Media/\(destinationPath)\(eventSuffix)"
            }
            updated.append(asset)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        do {
            try await library.updateLocations(updated)
            return destinationPath
        } catch {
            try? FileManager.default.moveItem(at: destination, to: source)
            throw error
        }
    }

    private func folderURL(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw LibraryError.invalidRelativePath(relativePath)
        }
        let url = relativePath.isEmpty ? media : media.appendingPathComponent(relativePath)
        let boundary = media.path + "/"
        guard url.standardizedFileURL == media || url.standardizedFileURL.path.hasPrefix(boundary),
            FileManager.default.fileExists(atPath: url.path)
        else { throw LibraryError.invalidRelativePath(relativePath) }
        return url.standardizedFileURL
    }

    private func validateMutableFolder(_ relativePath: String) throws {
        guard !relativePath.isEmpty, relativePath != "Inbox" else {
            throw LibraryError.invalidRelativePath(relativePath)
        }
        _ = try folderURL(relativePath)
    }

    private func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            throw LibraryError.invalidRelativePath(name)
        }
    }

    private func uniqueFolderURL(named name: String, in parent: URL) -> URL {
        uniqueURL(named: name, in: parent, preservesExtension: false)
    }

    private func uniqueFileURL(named name: String, in parent: URL) -> URL {
        uniqueURL(named: name, in: parent, preservesExtension: true)
    }

    private func uniqueURL(named name: String, in parent: URL, preservesExtension: Bool) -> URL {
        let proposed = parent.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: proposed.path) else {
            let ns = name as NSString
            let stem = preservesExtension ? ns.deletingPathExtension : name
            let ext = preservesExtension ? ns.pathExtension : ""
            var index = 2
            while true {
                let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
                let candidate = parent.appendingPathComponent(candidateName)
                if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                index += 1
            }
        }
        return proposed
    }

    private func relative(_ url: URL) -> String {
        guard url.standardizedFileURL != media else { return "" }
        return String(url.standardizedFileURL.path.dropFirst(media.path.count + 1))
    }

    private func rollback(_ moves: [(URL, URL)]) {
        for (source, destination) in moves.reversed() {
            try? FileManager.default.moveItem(at: destination, to: source)
        }
    }
}
