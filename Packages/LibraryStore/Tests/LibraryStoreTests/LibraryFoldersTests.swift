import CoreModel
import Foundation
import LibraryStore
import Testing

private struct FolderTestTrashManager: FileTrashManaging {
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

@Test func folderCreateMoveRenameTrashAndRestorePreserveAssetIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-folder-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent("TestTrash", isDirectory: true)
    let store = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json")),
        trashManager: FolderTestTrashManager(directory: trash)
    )
    let folders = LibraryFolders(
        root: root,
        library: store,
        trashManager: FolderTestTrashManager(directory: trash)
    )

    let id = AssetID(rawValue: "stable-asset")
    let media = LibraryLayout.inbox(in: root).appendingPathComponent("Recording.mov")
    try Data("immutable".utf8).write(to: media)
    let record = AssetRecord(
        id: id,
        relativePath: "Media/Inbox/Recording.mov",
        displayName: "Recording.mov",
        kind: .video,
        createdAt: .now,
        importedAt: .now,
        byteSize: 9,
        contentHash: "stable-hash",
        duration: RationalTime(seconds: 3),
        ingestState: .ready
    )
    try await store.insert(record)
    try await store.storeEventTrack(
        EventTrack(assetID: id, alignment: .exact(offset: .zero), samples: [], clicks: [])
    )
    let item = TimelineItem(
        id: ItemID(rawValue: "stable-item"),
        assetID: id,
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 3))
    )
    let project = try ProjectDocument(
        id: ProjectID(rawValue: "stable-project"),
        name: "Stable Project",
        timeline: Timeline(video: [item]),
        createdAt: .now,
        modifiedAt: .now
    )
    try await store.saveProject(project)

    #expect(try await folders.createFolder(named: "Demos", in: "") == "Demos")
    #expect(try await folders.createFolder(named: "Demos", in: "") == "Demos 2")
    #expect(try await folders.createFolder(named: "onboarding", in: "Demos") == "Demos/onboarding")
    _ = try await folders.move([id], to: "Demos/onboarding")
    #expect(try await store.asset(id: id)?.relativePath == "Media/Demos/onboarding/Recording.mov")
    #expect(
        try await store.asset(id: id)?.eventTrackPath
            == "Media/Demos/onboarding/Recording.events.json"
    )

    let renamed = try await folders.rename("Demos/onboarding", to: "launch")
    #expect(renamed == "Demos/launch")
    let moved = try await folders.moveFolder("Demos/launch", to: "")
    #expect(moved == "launch")
    #expect(try await store.asset(id: id)?.id == id)
    #expect(try await store.loadProject(id: project.id).timeline.video.first?.assetID == id)

    let tree = try await folders.tree(expanding: ["", "Demos", "launch"])
    #expect(tree.children?.contains(where: { $0.id == "launch" && $0.assetCount == 1 }) == true)
    #expect(tree.children?.first(where: { $0.id == "Demos" })?.children != nil)

    let assetTrash = try await folders.trash([id])
    #expect(try await store.asset(id: id) == nil)
    try await store.restore(assetTrash)
    #expect(try await store.asset(id: id)?.id == id)

    let folderTrash = try await folders.trashFolder("launch")
    #expect(
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Media/launch").path))
    try await folders.restoreFolder(folderTrash)
    #expect(try await store.asset(id: id)?.relativePath == "Media/launch/Recording.mov")
    #expect(try await store.projectsReferencing(assetIDs: [id]).map(\.name) == ["Stable Project"])
}
