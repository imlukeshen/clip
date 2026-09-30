import CoreModel
import Foundation
import LibraryStore
import Testing

@Suite("Referenced assets")
struct ReferencedAssetTests {
    @Test("A referenced file is indexed where it already lives")
    func referenceLeavesTheFileInPlace() async throws {
        let (root, outside) = try makeRoots(named: "reference")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        let original = outside.appendingPathComponent("notes.md")
        try Data("original body\n".utf8).write(to: original)

        let asset = referencedAsset(id: "ref-1", at: original)
        try await store.insertReference(asset, originalURL: original)

        // Indexed, but nothing was copied into the library.
        let stored = try #require(try await store.asset(id: asset.id))
        #expect(stored.isReferenced)
        #expect(FileManager.default.fileExists(atPath: original.path))
        // The library creates its folders, but must not have taken a copy.
        let media = LibraryLayout.media(in: root)
        let files = (FileManager.default.enumerator(atPath: media.path)?.allObjects ?? [])
            .compactMap { $0 as? String }
            .filter { !$0.hasSuffix("Inbox") }
        #expect(files.isEmpty, "library copied: \(files)")
    }

    @Test("A referenced asset resolves back to the original path")
    func referenceResolvesToOriginal() async throws {
        let (root, outside) = try makeRoots(named: "resolve")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        let original = outside.appendingPathComponent("report.pdf")
        try Data("pdf bytes\n".utf8).write(to: original)

        let asset = referencedAsset(id: "ref-2", at: original)
        try await store.insertReference(asset, originalURL: original)

        let resolved = try await store.withAssetFile(asset) { $0.standardizedFileURL }
        #expect(resolved == original.standardizedFileURL)
        // Crucially outside the library: this is the whole point of a reference.
        #expect(!resolved.path.hasPrefix(root.standardizedFileURL.path))
    }

    @Test("A reference without a bookmark key is refused")
    func referenceNeedsABookmarkKey() async throws {
        let (root, outside) = try makeRoots(named: "nokey")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        let original = outside.appendingPathComponent("loose.txt")
        try Data("x".utf8).write(to: original)

        var asset = referencedAsset(id: "ref-3", at: original)
        asset.externalBookmarkKey = nil

        await #expect(throws: LibraryError.self) {
            try await store.insertReference(asset, originalURL: original)
        }
    }
}

private func referencedAsset(id rawID: String, at url: URL) -> AssetRecord {
    AssetRecord(
        id: AssetID(rawValue: rawID),
        relativePath: url.path,
        displayName: url.lastPathComponent,
        kind: .text,
        container: url.pathExtension,
        codec: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        importedAt: Date(timeIntervalSince1970: 1_700_000_001),
        byteSize: 1,
        contentHash: "hash-\(rawID)",
        externalBookmarkKey: "external.\(rawID)",
        ingestState: .ready
    )
}

private func makeRoots(named name: String) throws -> (library: URL, outside: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("clip-reference-\(name)-\(UUID().uuidString)", isDirectory: true)
    let library = base.appendingPathComponent("Library", isDirectory: true)
    let outside = base.appendingPathComponent("Elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    return (library, outside)
}
