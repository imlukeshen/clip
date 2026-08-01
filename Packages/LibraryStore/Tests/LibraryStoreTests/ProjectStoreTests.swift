import CoreModel
import Foundation
import LibraryStore
import Testing

@Test func projectSaveLoadSummaryAndHistoryAreDurable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-project-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    )
    let item = TimelineItem(
        id: ItemID(rawValue: "item-1"),
        assetID: AssetID(rawValue: "asset-1"),
        sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 4))
    )
    let document = try ProjectDocument(
        id: ProjectID(rawValue: "project-1"),
        name: "Demo",
        timeline: Timeline(video: [item]),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )

    try await store.saveProject(document)
    #expect(try await store.loadProject(id: document.id) == document)
    let summary = try #require(try await store.projects(limit: 10).first)
    #expect(summary.id == document.id)
    #expect(summary.itemCount == 1)
    #expect(summary.duration == RationalTime(seconds: 4))

    for index in 0..<205 {
        try await store.appendHistory(
            GraphPatch(ops: [.rename("Name \(index)")], label: "Rename", origin: .user),
            project: document.id
        )
    }
    let history = root.appendingPathComponent("Projects/project-1.reelproj/history")
    let files = try FileManager.default.contentsOfDirectory(
        at: history,
        includingPropertiesForKeys: nil
    )
    #expect(files.filter { $0.pathExtension == "json" }.count == 200)
}
