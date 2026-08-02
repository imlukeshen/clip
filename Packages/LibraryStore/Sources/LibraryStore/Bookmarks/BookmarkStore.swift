import Foundation

/// Persists and balances access to user-selected security-scoped locations.
public actor BookmarkStore {
    private let storageURL: URL
    private var cachedBookmarks: [String: Data]?

    /// Creates a bookmark store at an explicit durable location.
    public init(storageURL: URL) {
        self.storageURL = storageURL
        self.cachedBookmarks = nil
    }

    /// Creates a bookmark store in Application Support.
    public init() {
        let support =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        storageURL = support.appendingPathComponent("Reel/bookmarks.json")
        cachedBookmarks = nil
    }

    /// Stores a security-scoped bookmark for a user-selected URL.
    public func store(_ url: URL, key: String) throws {
        let data: Data
        do {
            data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw LibraryError.bookmarkCreationFailed(key)
        }
        var bookmarks = try loadedBookmarks()
        bookmarks[key] = data
        try persist(bookmarks)
        cachedBookmarks = bookmarks
    }

    /// Stores a bookmark plus the volume-stable file identifier used when a bookmark URL goes stale.
    public func storeFileReference(_ url: URL, key: String) throws {
        var bookmarks = try loadedBookmarks()
        var storedReference = false
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmarks[key] = bookmark
            storedReference = true
        }
        if let identifier = try? url.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier {
            bookmarks["\(key).resource-id"] = Data(String(describing: identifier).utf8)
            storedReference = true
        }
        guard storedReference else {
            throw LibraryError.bookmarkCreationFailed(key)
        }
        try persist(bookmarks)
        cachedBookmarks = bookmarks
    }

    /// Resolves a moved file by bookmark first, then by its stable identifier within one root.
    public func resolveFileReference(key: String, searching root: URL) throws -> URL {
        if let bookmarked = try? resolve(key: key),
            FileManager.default.fileExists(atPath: bookmarked.path)
        {
            return bookmarked
        }
        guard let data = try loadedBookmarks()["\(key).resource-id"],
            let expected = String(data: data, encoding: .utf8),
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileResourceIdentifierKey],
                options: [.skipsHiddenFiles]
            )
        else { throw LibraryError.bookmarkResolutionFailed(key) }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileResourceIdentifierKey]
            )
            guard values?.isRegularFile == true, let identifier = values?.fileResourceIdentifier else {
                continue
            }
            if String(describing: identifier) == expected { return url }
        }
        throw LibraryError.bookmarkResolutionFailed(key)
    }

    /// Resolves a bookmark without starting access. Prefer `withAccess` at call sites.
    public func resolve(key: String) throws -> URL {
        guard let data = try loadedBookmarks()[key] else {
            throw LibraryError.bookmarkNotFound(key)
        }
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw LibraryError.bookmarkResolutionFailed(key)
        }
        guard !isStale else {
            throw LibraryError.staleBookmark(key)
        }
        return url
    }

    /// Runs an asynchronous operation while a security scope is active.
    public func withAccess<T: Sendable>(
        key: String,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let url = try resolve(key: key)
        guard url.startAccessingSecurityScopedResource() else {
            throw LibraryError.securityScopeDenied(key)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try await body(url)
    }

    private func loadedBookmarks() throws -> [String: Data] {
        if let cachedBookmarks {
            return cachedBookmarks
        }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            cachedBookmarks = [:]
            return [:]
        }
        do {
            let bookmarks = try JSONDecoder().decode(
                [String: Data].self,
                from: Data(contentsOf: storageURL)
            )
            cachedBookmarks = bookmarks
            return bookmarks
        } catch {
            throw LibraryError.fileOperationFailed("load bookmarks")
        }
    }

    private func persist(_ bookmarks: [String: Data]) throws {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(bookmarks).write(to: storageURL, options: .atomic)
        } catch {
            throw LibraryError.fileOperationFailed("persist bookmarks")
        }
    }
}
