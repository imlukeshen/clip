import CoreModel
import Foundation
import LibraryStore
import Testing

private struct TemporaryTrashManager: FileTrashManaging {
    let directory: URL

    func trashItem(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            "\(UUID().uuidString)-\(url.lastPathComponent)"
        )
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

@Test func trashMovesEverySidecarWarnsForProjectsAndRestores() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-trash-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent("TestTrash", isDirectory: true)
    let store = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json")),
        trashManager: TemporaryTrashManager(directory: trash)
    )

    let id = AssetID(rawValue: "asset-trash")
    let assetDirectory = LibraryLayout.inbox(in: root)
    try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
    let media = assetDirectory.appendingPathComponent("asset-trash.mov")
    let event = assetDirectory.appendingPathComponent("asset-trash.events.json")
    let thumbnail = LibraryLayout.thumbnails(in: root).appendingPathComponent("asset-trash.thumb.heic")
    let peaks = LibraryLayout.peaks(in: root).appendingPathComponent("asset-trash.peaks.bin")
    try FileManager.default.createDirectory(
        at: LibraryLayout.thumbnails(in: root),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: LibraryLayout.peaks(in: root),
        withIntermediateDirectories: true
    )
    for url in [media, event, thumbnail, peaks] {
        try Data(url.lastPathComponent.utf8).write(to: url)
    }
    let record = AssetRecord(
        id: id,
        relativePath: "Media/Inbox/asset-trash.mov",
        displayName: "Demo.mov",
        kind: .video,
        createdAt: .now,
        importedAt: .now,
        byteSize: 10,
        contentHash: "trash-hash",
        duration: RationalTime(seconds: 2),
        eventTrackPath: "Media/Inbox/asset-trash.events.json",
        thumbnailPath: ".reel/thumbs/asset-trash.thumb.heic",
        peaksPath: ".reel/peaks/asset-trash.peaks.bin",
        ingestState: .ready
    )
    try await store.insert(record)

    let item = TimelineItem(
        id: ItemID(rawValue: "item-trash"),
        assetID: id,
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 2))
    )
    let project = try ProjectDocument(
        id: ProjectID(rawValue: "project-trash"),
        name: "Referenced Demo",
        timeline: Timeline(video: [item]),
        createdAt: .now,
        modifiedAt: .now
    )
    try await store.saveProject(project)
    #expect(try await store.projectsReferencing(assetIDs: [id]).map(\.name) == ["Referenced Demo"])

    let receipt = try await store.trash(assetIDs: [id])
    #expect(try await store.asset(id: id) == nil)
    #expect(!FileManager.default.fileExists(atPath: media.path))
    #expect(receipt.items.first?.movedFiles.count == 5)

    try await store.restore(receipt)
    let restored = try #require(try await store.asset(id: id))
    #expect(restored.id == record.id)
    #expect(restored.relativePath == record.relativePath)
    #expect(restored.displayName == record.displayName)
    #expect(restored.kind == record.kind)
    #expect(restored.createdAt == record.createdAt)
    #expect(restored.importedAt == record.importedAt)
    #expect(restored.byteSize == record.byteSize)
    #expect(restored.contentHash == record.contentHash)
    #expect(restored.duration == record.duration)
    #expect(restored.eventTrackPath == record.eventTrackPath)
    #expect(restored.thumbnailPath == record.thumbnailPath)
    #expect(restored.peaksPath == record.peaksPath)
    #expect(restored.ingestState == record.ingestState)
    #expect(FileManager.default.fileExists(atPath: media.path))
    #expect(try await store.projectsReferencing(assetIDs: [id]).map(\.name) == ["Referenced Demo"])
}
