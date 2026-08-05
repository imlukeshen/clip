@preconcurrency import AVFoundation
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

    @Test("Project names trim, persist through the graph, and undo exactly")
    func renameProject() throws {
        let original = try document()
        let editor = makeEditor(document: original)

        #expect(editor.renameProject(to: "  Launch Cut  "))
        #expect(editor.document.name == "Launch Cut")
        #expect(editor.undoManager.canUndo)

        editor.undo()
        #expect(editor.document == original)
        #expect(!editor.renameProject(to: "   \n "))
        #expect(editor.document == original)
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

    @Test("Live Text maps project time to source time and redacts in one undo")
    func liveTextRedaction() throws {
        var original = try document()
        original.timeline.video[0].sourceRange.start = RationalTime(seconds: 10)
        original.timeline.video[0].speed = 2
        let editor = makeEditor(document: original)
        editor.seek(to: RationalTime(seconds: 1))

        #expect(
            editor.sourceMomentAtPlayhead
                == EditorSourceMoment(
                    assetID: AssetID(rawValue: "asset"),
                    time: RationalTime(seconds: 12)
                )
        )

        editor.redactCurrentRegions([
            NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
            NormalizedRect(x: 0.5, y: 0.6, width: 0.2, height: 0.1),
        ])

        #expect(editor.document.timeline.video[0].effects.count == 2)
        #expect(editor.document.timeline.video[0].effects.allSatisfy { $0.kind == .blur })
        editor.undo()
        #expect(editor.document == original)
    }

    @Test("Preview dragging positions the visible clip and remains exactly undoable")
    func previewDraggingPositionsClip() throws {
        let original = try document()
        let itemID = try #require(original.timeline.video.first?.id)
        let editor = makeEditor(document: original)
        editor.seek(to: RationalTime(seconds: 1))

        editor.translateSelectedClip(by: NormalizedPoint(x: 0.25, y: -0.1))

        #expect(editor.selection == [itemID])
        #expect(editor.selectedTransform.translationX == 0.25)
        #expect(editor.selectedTransform.translationY == -0.1)
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

    @Test("Automatic recordings append once at the end of the timeline")
    func appendCapturedRecording() throws {
        let editor = makeEditor(document: try document())
        let recording = AssetRecord(
            id: AssetID(rawValue: "second-recording"),
            relativePath: "Media/Inbox/second.mov",
            displayName: "Second Recording.mov",
            kind: .video,
            createdAt: Date(timeIntervalSince1970: 2),
            importedAt: Date(timeIntervalSince1970: 2),
            byteSize: 2,
            contentHash: "second-hash",
            duration: RationalTime(seconds: 4),
            ingestState: .ready
        )
        let track = EventTrack(
            assetID: recording.id,
            alignment: .exact(offset: .zero),
            samples: [],
            clicks: []
        )

        #expect(editor.appendCapturedAsset(recording, eventTrack: track))
        #expect(
            editor.document.timeline.video.map(\.assetID) == [
                AssetID(rawValue: "asset"), recording.id,
            ])
        #expect(editor.document.timeline.video[1].timelineStart == RationalTime(seconds: 6))
        #expect(editor.playhead == RationalTime(seconds: 6))
        #expect(editor.selection == [editor.document.timeline.video[1].id])
        #expect(editor.eventTracks[recording.id] == track)

        #expect(!editor.appendCapturedAsset(recording, eventTrack: track))
        #expect(editor.document.timeline.video.count == 2)
    }

    @Test("Overlay and detached audio tracks are independently editable")
    func overlaysAndDetachedAudio() throws {
        let editor = makeEditor(document: try document())
        let overlay = record(
            id: "overlay",
            displayName: "Overlay.mov",
            duration: RationalTime(seconds: 2),
            hasAudio: true
        )

        editor.addOverlayTrack()
        editor.seek(to: RationalTime(seconds: 1))
        #expect(editor.insert(overlay))

        #expect(editor.document.timeline.videoTracks.count == 2)
        #expect(
            editor.document.timeline.videoTracks[1].items[0].timelineStart
                == RationalTime(seconds: 1))
        #expect(editor.targetedVideoTrack?.name == "V2")

        editor.separateSelectedAudio()

        #expect(editor.document.timeline.audioTracks.count == 2)
        #expect(editor.selectedTrackKind == .audio)
        let detachedID = try #require(editor.selectedItem?.id)
        editor.deleteSelected()
        #expect(editor.document.item(detachedID) == nil)
        #expect(editor.document.timeline.videoTracks[1].items.count == 1)
        editor.undo()
        #expect(editor.document.item(detachedID) != nil)
    }

    @Test("Nested media selects and deletes as one undoable group")
    func nestedMedia() throws {
        let editor = makeEditor(document: try document())
        let second = record(
            id: "second",
            displayName: "Second.mov",
            duration: RationalTime(seconds: 2),
            hasAudio: false
        )
        #expect(editor.insert(second))
        let ids = editor.document.timeline.video.map(\.id)
        editor.select(ids[0])
        editor.select(ids[1], extending: true)

        editor.nestSelection()

        let nestIDs = Set(editor.document.timeline.video.compactMap(\.nestID))
        #expect(nestIDs.count == 1)
        editor.select(ids[0])
        #expect(editor.selection == Set(ids))
        editor.deleteSelected()
        #expect(editor.document.timeline.video.isEmpty)
        editor.undo()
        #expect(Set(editor.document.timeline.video.map(\.id)) == Set(ids))
    }

    @Test("Overlay-only projects are not presented as empty")
    func overlayOnlyProjectIsNotEmpty() throws {
        let overlay = TimelineItem(
            id: ItemID(rawValue: "overlay-item"),
            assetID: AssetID(rawValue: "asset"),
            sourceRange: TimeRange(
                start: .zero,
                duration: RationalTime(seconds: 3)
            )
        )
        let project = try ProjectDocument(
            id: ProjectID(rawValue: "overlay-project"),
            name: "Overlay",
            timeline: Timeline(videoTracks: [
                Track(id: TrackID(rawValue: "v1"), name: "V1"),
                Track(id: TrackID(rawValue: "v2"), name: "V2", items: [overlay]),
            ]),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let editor = makeEditor(document: project)

        #expect(editor.timelineMediaCount == 1)
        #expect(!editor.isTimelineEmpty)
    }

    @Test("Deleting the final visual media clears the installed player item")
    func deletingFinalVisualMediaClearsPlayer() throws {
        let original = try document()
        let itemID = try #require(original.timeline.video.first?.id)
        let editor = makeEditor(document: original)
        editor.player.replaceCurrentItem(
            with: AVPlayerItem(asset: AVMutableComposition())
        )
        #expect(editor.player.currentItem != nil)

        editor.seek(to: RationalTime(seconds: 2))
        editor.select(itemID)
        editor.deleteSelected()

        #expect(editor.document.timeline.video.isEmpty)
        #expect(!editor.hasVisualTimelineMedia)
        #expect(editor.player.currentItem == nil)
        #expect(editor.playhead == .zero)
        #expect(!editor.isPlaying)
        #expect(!editor.isBuilding)
        #expect(editor.notice == "Media deleted.")
    }

    @Test("Deleting the final video clears its frame when audio remains")
    func deletingFinalVideoWithAudioRemainingClearsPlayer() throws {
        var original = try document()
        original.timeline.audioTracks = [
            Track(
                id: TrackID(rawValue: "a1"),
                name: "A1",
                items: [
                    TimelineItem(
                        id: ItemID(rawValue: "audio-item"),
                        assetID: AssetID(rawValue: "asset"),
                        sourceRange: TimeRange(
                            start: .zero,
                            duration: RationalTime(seconds: 6)
                        )
                    )
                ]
            )
        ]
        let videoID = try #require(original.timeline.video.first?.id)
        let editor = makeEditor(document: original)
        editor.player.replaceCurrentItem(
            with: AVPlayerItem(asset: AVMutableComposition())
        )

        editor.seek(to: RationalTime(seconds: 2))
        editor.select(videoID)
        editor.deleteSelected()

        #expect(editor.document.timeline.audio.count == 1)
        #expect(!editor.isTimelineEmpty)
        #expect(!editor.hasVisualTimelineMedia)
        #expect(editor.player.currentItem == nil)
        #expect(editor.playhead == .zero)
        #expect(!editor.isPlaying)
        #expect(!editor.isBuilding)
    }

    private func makeEditor(
        document: ProjectDocument,
        eventTracks: [AssetID: EventTrack] = [:],
        clickTrackingState: ClickTrackingState = .disabled(reason: "off")
    ) -> EditorViewModel {
        let record = record(
            id: "asset",
            displayName: "asset.mov",
            duration: RationalTime(seconds: 6),
            hasAudio: true
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

    private func record(
        id: String,
        displayName: String,
        duration: RationalTime,
        hasAudio: Bool
    ) -> AssetRecord {
        AssetRecord(
            id: AssetID(rawValue: id),
            relativePath: "Assets/\(displayName)",
            displayName: displayName,
            kind: .video,
            createdAt: Date(timeIntervalSince1970: 1),
            importedAt: Date(timeIntervalSince1970: 1),
            byteSize: 1,
            contentHash: "hash-\(id)",
            duration: duration,
            hasAudio: hasAudio,
            ingestState: .ready
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
