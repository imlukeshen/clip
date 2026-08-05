import CoreModel
import Foundation
import LibraryStore
import Testing

@Test func textAssetsAreImportedWritableUnlikeOtherKinds() async throws {
    let root = try temporaryTextRoot(named: "writable")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    )
    let text = try textAsset(id: "note-1", root: root, contents: "# Title\n")

    try await store.insert(text)

    let mode = try posixMode(of: root.appendingPathComponent(text.relativePath))
    // Owner-writable bit is set for text, unlike the 0o444 every other kind gets.
    #expect(mode & 0o200 != 0)
}

@Test func savingTextContentsRewritesBytesHashAndSize() async throws {
    let root = try temporaryTextRoot(named: "save")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    )
    let text = try textAsset(id: "note-2", root: root, contents: "old\n")
    try await store.insert(text)

    let updatedBytes = Data("a much longer replacement body\n".utf8)
    let newHash = "hash-updated-note-2"
    let updated = try await store.saveTextContents(
        updatedBytes,
        for: text.id,
        contentHash: newHash
    )

    #expect(updated.contentHash == newHash)
    #expect(updated.byteSize == Int64(updatedBytes.count))

    let onDisk = try Data(contentsOf: root.appendingPathComponent(text.relativePath))
    #expect(onDisk == updatedBytes)

    // The record is queryable by its new hash, and the file is still writable.
    #expect(try await store.asset(contentHash: newHash)?.id == text.id)
    let mode = try posixMode(of: root.appendingPathComponent(text.relativePath))
    #expect(mode & 0o200 != 0)
}

@Test func savingContentsRefusesNonTextAssets() async throws {
    let root = try temporaryTextRoot(named: "refuse")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    )
    let video = try mediaAsset(id: "clip-1", root: root)
    try await store.insert(video)

    await #expect(throws: LibraryError.self) {
        _ = try await store.saveTextContents(
            Data("nope".utf8),
            for: video.id,
            contentHash: "hash-nope"
        )
    }
}

// MARK: - Fixtures

private func textAsset(id rawID: String, root: URL, contents: String) throws -> AssetRecord {
    let id = AssetID(rawValue: rawID)
    let folder = LibraryLayout.inbox(in: root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let mediaURL = folder.appendingPathComponent("\(rawID).md")
    try Data(contents.utf8).write(to: mediaURL)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    return AssetRecord(
        id: id,
        relativePath: "Media/Inbox/\(rawID).md",
        displayName: "\(rawID).md",
        kind: .text,
        container: "md",
        codec: nil,
        createdAt: createdAt,
        importedAt: createdAt.addingTimeInterval(1),
        byteSize: Int64(Data(contents.utf8).count),
        contentHash: "hash-\(rawID)",
        ingestState: .ready
    )
}

private func mediaAsset(id rawID: String, root: URL) throws -> AssetRecord {
    let id = AssetID(rawValue: rawID)
    let folder = LibraryLayout.inbox(in: root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let mediaURL = folder.appendingPathComponent("\(rawID).mov")
    try Data("clip".utf8).write(to: mediaURL)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_100)
    return AssetRecord(
        id: id,
        relativePath: "Media/Inbox/\(rawID).mov",
        displayName: "\(rawID).mov",
        kind: .video,
        container: "mov",
        codec: "h264",
        createdAt: createdAt,
        importedAt: createdAt.addingTimeInterval(1),
        byteSize: 4,
        contentHash: "hash-\(rawID)",
        duration: RationalTime(seconds: 1),
        nominalFPS: 60,
        hasAudio: false,
        ingestState: .ready
    )
}

private func posixMode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue
}

private func temporaryTextRoot(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-text-writable-\(name)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
