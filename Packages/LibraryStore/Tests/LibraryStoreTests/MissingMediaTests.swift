import CoreModel
import Foundation
import LibraryStore
import Testing

@Test func bookmarkResolvesClosedAppRenameAndLocateClearsMissingState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-missing-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmarkURL = root.appendingPathComponent("bookmarks.json")
    let id = AssetID(rawValue: "missing-asset")
    let original = LibraryLayout.inbox(in: root).appendingPathComponent("Walkthrough.mov")

    do {
        let store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: bookmarkURL)
        )
        try Data("same-media".utf8).write(to: original)
        try await store.insert(
            AssetRecord(
                id: id,
                relativePath: "Media/Inbox/Walkthrough.mov",
                displayName: "Walkthrough.mov",
                kind: .video,
                createdAt: .now,
                importedAt: .now,
                byteSize: 10,
                contentHash: "fixture-hash",
                duration: RationalTime(seconds: 2),
                ingestState: .ready
            )
        )
    }

    let demos = LibraryLayout.media(in: root).appendingPathComponent("Demos", isDirectory: true)
    try FileManager.default.createDirectory(at: demos, withIntermediateDirectories: true)
    let renamed = demos.appendingPathComponent("Renamed.mov")
    try FileManager.default.moveItem(at: original, to: renamed)

    let reopened = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: bookmarkURL)
    )
    await reopened.refreshLocations()
    #expect(try await reopened.url(for: id).standardizedFileURL == renamed.standardizedFileURL)
    #expect(try await reopened.asset(id: id)?.relativePath == "Media/Demos/Renamed.mov")
    #expect(try await reopened.asset(id: id)?.isMissing == false)

    try FileManager.default.removeItem(at: renamed)
    await reopened.refreshLocations()
    #expect(try await reopened.asset(id: id)?.isMissing == true)

    let replacement = root.appendingPathComponent("replacement.mov")
    try Data("same-media".utf8).write(to: replacement)
    try await reopened.relink(assetID: id, to: replacement)
    #expect(try await reopened.asset(id: id)?.isMissing == false)
    #expect(try await reopened.url(for: id).standardizedFileURL == replacement.standardizedFileURL)
}
