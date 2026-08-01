import CoreModel
import Foundation
import LibraryStore
import Testing

@Test func rebuildIndexRestoresFiftyIdenticalAssetRecords() async throws {
    let root = try temporaryDirectory(named: "rebuild")
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmarks = BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    var expected: [AssetRecord] = []

    do {
        let store = try await LibraryStore(root: root, bookmarks: bookmarks)
        for index in 0..<50 {
            let record = try syntheticAsset(index: index, root: root)
            try await store.insert(record)
            expected.append(record)
        }
        #expect(try await store.assets(kind: nil, limit: 100, offset: 0).count == 50)
    }

    try FileManager.default.removeItem(at: root.appendingPathComponent("Library.sqlite"))

    let rebuilt = try await LibraryStore(root: root, bookmarks: bookmarks)
    try await rebuilt.rebuildIndex { _ in }
    let actual = try await rebuilt.assets(kind: nil, limit: 100, offset: 0)
    expected.sort { $0.createdAt > $1.createdAt }

    #expect(actual == expected)
}

@Test func importedAssetIsMadeReadOnlyAndCanBeFoundByHash() async throws {
    let root = try temporaryDirectory(named: "immutable")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    )
    let record = try syntheticAsset(index: 7, root: root)

    try await store.insert(record)

    #expect(try await store.asset(id: record.id) == record)
    #expect(try await store.asset(contentHash: record.contentHash) == record)
    #expect(try await store.url(for: record.id).path.hasSuffix(record.relativePath))
    let attributes = try FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent(record.relativePath).path
    )
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o222 == 0)
}

private func syntheticAsset(index: Int, root: URL) throws -> AssetRecord {
    let id = AssetID(rawValue: String(format: "asset-%03d", index))
    let folder = root.appendingPathComponent("Assets/2026-08-01", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let mediaURL = folder.appendingPathComponent("\(id.rawValue).mov")
    try Data("asset-\(index)".utf8).write(to: mediaURL)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
    return AssetRecord(
        id: id,
        relativePath: "Assets/2026-08-01/\(id.rawValue).mov",
        displayName: "Recording \(index).mov",
        kind: .video,
        container: "mov",
        codec: "h264",
        createdAt: createdAt,
        importedAt: createdAt.addingTimeInterval(5),
        byteSize: Int64(Data("asset-\(index)".utf8).count),
        contentHash: String(format: "hash-%03d", index),
        width: 1_920,
        height: 1_080,
        duration: RationalTime(seconds: Double(index + 1)),
        nominalFPS: 60,
        isVariableFPS: index.isMultiple(of: 3),
        hasAudio: true,
        preferredTransform: .object(["a": .number(1), "d": .number(1)]),
        eventTrackPath: index.isMultiple(of: 2)
            ? "Assets/2026-08-01/\(id.rawValue).events.json" : nil,
        eventAlignment: index.isMultiple(of: 2) ? .exact : nil,
        thumbnailPath: "Assets/2026-08-01/\(id.rawValue).thumb.heic",
        peaksPath: "Assets/2026-08-01/\(id.rawValue).peaks.bin",
        ingestState: .ready
    )
}

private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-library-tests-\(name)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
