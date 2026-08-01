import Foundation
import LibraryStore
import Testing

@Test func bookmarkStorePersistsAndResolvesSelectedDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-bookmark-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let storageURL = root.appendingPathComponent("bookmarks.json")
    let selected = root.appendingPathComponent("Selected", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)

    let firstStore = BookmarkStore(storageURL: storageURL)
    try await firstStore.store(selected, key: "library")

    let reopenedStore = BookmarkStore(storageURL: storageURL)
    let resolved = try await reopenedStore.resolve(key: "library")
    #expect(resolved.standardizedFileURL == selected.standardizedFileURL)
}
