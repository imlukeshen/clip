import CoreModel
import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

@MainActor
@Suite("Editor mutation path")
struct EditorViewModelTests {
    @Test("Perform registers an exact undo and redo")
    func undoAndRedo() throws {
        let original = try document()
        let itemID = try #require(original.timeline.video.first?.id)
        let editor = makeEditor(document: original)

        try editor.perform(TimelineEditPlanner.setSpeed(of: itemID, to: 2))
        #expect(editor.document.timeline.video[0].speed == 2)
        #expect(editor.undoManager.canUndo)

        editor.undo()
        #expect(editor.document == original)
        #expect(editor.undoManager.canRedo)

        editor.redo()
        #expect(editor.document.timeline.video[0].speed == 2)
    }

    @Test("Editor split uses the same patch path and preserves duration")
    func split() throws {
        let original = try document()
        let editor = makeEditor(document: original)
        let itemID = try #require(original.timeline.video.first?.id)
        editor.select(itemID)
        editor.seek(to: RationalTime(seconds: 2))

        editor.splitAtPlayhead()

        #expect(editor.document.timeline.video.count == 2)
        #expect(editor.document.duration == original.duration)
        editor.undo()
        #expect(editor.document == original)
    }

    private func makeEditor(document: ProjectDocument) -> EditorViewModel {
        let record = AssetRecord(
            id: AssetID(rawValue: "asset"),
            relativePath: "Assets/asset.mov",
            displayName: "asset.mov",
            kind: .video,
            createdAt: Date(timeIntervalSince1970: 1),
            importedAt: Date(timeIntervalSince1970: 1),
            byteSize: 1,
            contentHash: "hash",
            duration: RationalTime(seconds: 6),
            ingestState: .ready
        )
        return EditorViewModel(
            document: document,
            assets: [record.id: record],
            buildsPlayback: false,
            resolving: { _ in URL(fileURLWithPath: "/tmp/asset.mov") },
            persisting: { _, _ in }
        )
    }

    private func document() throws -> ProjectDocument {
        try ProjectDocument(
            id: ProjectID(rawValue: "project"),
            name: "Demo",
            timeline: Timeline(video: [
                TimelineItem(
                    id: ItemID(rawValue: "item"),
                    assetID: AssetID(rawValue: "asset"),
                    sourceRange: TimeRange(
                        start: .zero,
                        duration: RationalTime(seconds: 6)
                    )
                )
            ]),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
