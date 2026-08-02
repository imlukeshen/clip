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

    @Test("Effect actions use the mutation path and remain exactly undoable")
    func addEffectAndUndo() throws {
        let original = try document()
        let editor = makeEditor(document: original)
        let itemID = try #require(original.timeline.video.first?.id)

        editor.addZoom(to: itemID)

        #expect(editor.document.timeline.video[0].effects.count == 1)
        #expect(editor.document.timeline.video[0].effects[0].kind == .zoom)
        editor.undo()
        #expect(editor.document == original)
    }

    @Test("Click-derived zooms form one patch and preserve manual zooms")
    func autoZoomAndUndo() throws {
        var original = try document()
        let itemID = try #require(original.timeline.video.first?.id)
        let manual = ZoomEffect(
            id: EffectID(rawValue: "manual-zoom"),
            range: TimeRange(start: .zero, duration: RationalTime(seconds: 1)),
            center: NormalizedPoint(x: 0.5, y: 0.5),
            scale: 1.4
        )
        original.timeline.video[0].effects = [.zoom(manual)]
        let track = EventTrack(
            assetID: AssetID(rawValue: "asset"),
            alignment: .exact(offset: .zero),
            samples: [],
            clicks: [
                ClickEvent(
                    time: RationalTime(seconds: 2),
                    point: NormalizedPoint(x: 0.25, y: 0.75),
                    button: .left,
                    clickCount: 1
                ),
                ClickEvent(
                    time: RationalTime(seconds: 2.5),
                    point: NormalizedPoint(x: 0.75, y: 0.25),
                    button: .left,
                    clickCount: 1
                ),
            ]
        )
        let editor = makeEditor(
            document: original,
            eventTracks: [track.assetID: track],
            clickTrackingState: .enabled(bufferDurationSeconds: 300)
        )
        editor.select(itemID)

        editor.autoZoomSelectedClip()

        let zooms = editor.document.timeline.video[0].effects.compactMap { effect in
            if case .zoom(let zoom) = effect { return zoom }
            return nil
        }
        #expect(zooms.count == 2)
        #expect(zooms.contains { $0.id == manual.id && $0.source == .manual })
        #expect(zooms.count { $0.source == .derivedFromClicks } == 1)
        #expect(
            editor.timelineClickMarkers.map(\.timelineTime) == [
                RationalTime(seconds: 2), RationalTime(seconds: 2.5),
            ])

        editor.undo()
        #expect(editor.document == original)
    }

    @Test("Denied Accessibility leaves editing available with a clear auto-zoom reason")
    func deniedClickTracking() throws {
        let original = try document()
        let editor = makeEditor(
            document: original,
            clickTrackingState: .disabled(reason: "Accessibility access is off.")
        )
        editor.select(try #require(original.timeline.video.first?.id))

        editor.autoZoomSelectedClip()

        #expect(editor.document == original)
        #expect(editor.autoZoomUnavailableReason == "Accessibility access is off.")
        #expect(editor.notice == "Accessibility access is off.")
    }

    private func makeEditor(
        document: ProjectDocument,
        eventTracks: [AssetID: EventTrack] = [:],
        clickTrackingState: ClickTrackingState = .disabled(reason: "off")
    ) -> EditorViewModel {
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
            eventTracks: eventTracks,
            clickTrackingState: clickTrackingState,
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
