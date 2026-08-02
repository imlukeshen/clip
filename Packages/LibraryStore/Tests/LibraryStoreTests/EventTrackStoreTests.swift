import CoreModel
import Foundation
import LibraryStore
import Testing

@Test func eventTrackSidecarUpdatesMetadataAndSurvivesIndexRebuild() async throws {
    let root = try eventTrackTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmarks = BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    let assetID = AssetID(rawValue: "asset-events")
    let folder = root.appendingPathComponent("Assets/2026-08-01", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: folder.appendingPathComponent("asset-events.mov"))
    let record = AssetRecord(
        id: assetID,
        relativePath: "Assets/2026-08-01/asset-events.mov",
        displayName: "Recording.mov",
        kind: .video,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        importedAt: Date(timeIntervalSince1970: 1_700_000_001),
        byteSize: 5,
        contentHash: "events-hash",
        duration: RationalTime(seconds: 3),
        ingestState: .ready
    )
    let track = EventTrack(
        assetID: assetID,
        alignment: .estimated(offset: .zero, confidence: 0.8),
        samples: [],
        clicks: [
            ClickEvent(
                time: RationalTime(seconds: 1),
                point: NormalizedPoint(x: 0.25, y: 0.75),
                button: .left,
                clickCount: 1
            )
        ]
    )

    do {
        let store = try await LibraryStore(root: root, bookmarks: bookmarks)
        try await store.insert(record)
        let updated = try await store.storeEventTrack(track)
        #expect(updated.eventAlignment == .estimated)
        #expect(updated.eventTrackPath == "Assets/2026-08-01/asset-events.events.json")
        #expect(try await store.eventTrack(for: assetID) == track)
    }

    try FileManager.default.removeItem(at: root.appendingPathComponent("Library.sqlite"))
    let rebuilt = try await LibraryStore(root: root, bookmarks: bookmarks)
    try await rebuilt.rebuildIndex { _ in }

    #expect(try await rebuilt.eventTrack(for: assetID) == track)
    #expect(try await rebuilt.asset(id: assetID)?.eventAlignment == .estimated)
}

private func eventTrackTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-library-events-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
