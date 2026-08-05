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
        let index = FolderTreeIndex(assets: assets)
        return try node(relativePath: "", expanding: expanding, index: index, forceLoad: true)
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

    /// Renames an indexed file without changing its stable asset identity.
    /// When the user omits an extension, the source extension is retained so a
    /// friendly Finder-style rename cannot accidentally change the media type.
    @discardableResult
    public func renameAsset(_ assetID: AssetID, to proposedName: String) async throws
        -> AssetRecord
    {
        guard var asset = try await library.asset(id: assetID) else {
            throw LibraryError.assetNotFound(assetID)
        }
        let source = root.appendingPathComponent(asset.relativePath)
        let requestedName = try normalizedAssetName(proposedName, source: source)
        guard requestedName != source.lastPathComponent else { return asset }

        let proposedDestination = source.deletingLastPathComponent()
            .appendingPathComponent(requestedName)
        let isCaseOnlyRename =
            source.path.caseInsensitiveCompare(proposedDestination.path)
            == .orderedSame
        let destination =
            isCaseOnlyRename
            ? proposedDestination
            : uniqueAssetURL(
                named: requestedName,
                in: source.deletingLastPathComponent(),
                hasEventTrack: asset.eventTrackPath != nil
            )
        var moves: [(URL, URL)] = []
        do {
            try moveItem(at: source, to: destination, recording: &moves)
            asset.relativePath = "Media/\(relative(destination))"
            asset.displayName = destination.lastPathComponent

            if let eventPath = asset.eventTrackPath {
                let eventSource = root.appendingPathComponent(eventPath)
                if FileManager.default.fileExists(atPath: eventSource.path) {
                    let eventDestination = eventSidecarURL(for: destination)
                    try moveItem(at: eventSource, to: eventDestination, recording: &moves)
                    asset.eventTrackPath = "Media/\(relative(eventDestination))"
                }
            }
            try await library.updateLocations([asset])
            return asset
        } catch {
            rollback(moves)
            throw error
        }
    }

    /// Every internal folder that can receive a file, including collapsed
    /// descendants. This powers Move To menus without forcing the sidebar open.
    public func destinations() throws -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: media,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        var result: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            result.append(relative(url))
        }
        return result.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
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
                let proposed = destinationFolder.appendingPathComponent(source.lastPathComponent)
                guard source.standardizedFileURL != proposed.standardizedFileURL else {
                    updated.append(asset)
                    continue
                }
                let destination = uniqueAssetURL(
                    named: source.lastPathComponent,
                    in: destinationFolder,
                    hasEventTrack: asset.eventTrackPath != nil
                )
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
        index: FolderTreeIndex,
        forceLoad: Bool = false
    ) throws -> FolderNode {
        let url = try folderURL(relativePath)
        let count = index.directAssetCounts[relativePath, default: 0]
        let shouldLoad = forceLoad || expanding.contains(relativePath)
        let children: [FolderNode]?
        if shouldLoad {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let knownFileNames = index.knownFileNames[relativePath, default: []]
            let folders = entries.filter { child in
                !knownFileNames.contains(child.lastPathComponent)
                    && (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            let sortedFolders = folders.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            children = try sortedFolders.map { child in
                let childPath = relative(child)
                return try node(
                    relativePath: childPath,
                    expanding: expanding,
                    index: index
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
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..")
        else {
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
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/") else {
            throw LibraryError.invalidRelativePath(name)
        }
    }

    private func normalizedAssetName(_ proposedName: String, source: URL) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateName(trimmed)
        let sourceExtension = source.pathExtension
        guard !sourceExtension.isEmpty, (trimmed as NSString).pathExtension.isEmpty else {
            return trimmed
        }
        return "\(trimmed).\(sourceExtension)"
    }

    private func uniqueAssetURL(named name: String, in parent: URL, hasEventTrack: Bool) -> URL {
        let proposed = parent.appendingPathComponent(name)
        if !assetDestinationExists(proposed, hasEventTrack: hasEventTrack) { return proposed }

        let ns = name as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = parent.appendingPathComponent(candidateName)
            if !assetDestinationExists(candidate, hasEventTrack: hasEventTrack) { return candidate }
            index += 1
        }
    }

    private func assetDestinationExists(_ url: URL, hasEventTrack: Bool) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        return hasEventTrack
            && FileManager.default.fileExists(atPath: eventSidecarURL(for: url).path)
    }

    private func eventSidecarURL(for mediaURL: URL) -> URL {
        mediaURL.deletingPathExtension().appendingPathExtension("events.json")
    }

    /// APFS is usually case-insensitive, so a direct move from `cut.mov` to
    /// `Cut.mov` can report that the destination already exists. Hop through a
    /// unique sibling while retaining both moves for transactional rollback.
    private func moveItem(
        at source: URL,
        to destination: URL,
        recording moves: inout [(URL, URL)]
    ) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        if source.path.caseInsensitiveCompare(destination.path) == .orderedSame {
            let temporary = source.deletingLastPathComponent().appendingPathComponent(
                ".clip-rename-\(UUID().uuidString)-\(source.lastPathComponent)"
            )
            try FileManager.default.moveItem(at: source, to: temporary)
            moves.append((source, temporary))
            try FileManager.default.moveItem(at: temporary, to: destination)
            moves.append((temporary, destination))
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
            moves.append((source, destination))
        }
    }

    private func uniqueFolderURL(named name: String, in parent: URL) -> URL {
        uniqueURL(named: name, in: parent, preservesExtension: false)
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

private struct FolderTreeIndex {
    var directAssetCounts: [String: Int] = [:]
    var knownFileNames: [String: Set<String>] = [:]

    init(assets: [AssetRecord]) {
        for asset in assets where asset.relativePath.hasPrefix("Media/") {
            let relativePath = String(asset.relativePath.dropFirst("Media/".count))
            let parent = (relativePath as NSString).deletingLastPathComponent
            let folder = parent == "." ? "" : parent
            directAssetCounts[folder, default: 0] += 1
            knownFileNames[folder, default: []].insert((relativePath as NSString).lastPathComponent)
            if let eventPath = asset.eventTrackPath, eventPath.hasPrefix("Media/") {
                let relativeEventPath = String(eventPath.dropFirst("Media/".count))
                let eventParent = (relativeEventPath as NSString).deletingLastPathComponent
                let eventFolder = eventParent == "." ? "" : eventParent
                knownFileNames[eventFolder, default: []].insert(
                    (relativeEventPath as NSString).lastPathComponent
                )
            }
        }
    }
}
