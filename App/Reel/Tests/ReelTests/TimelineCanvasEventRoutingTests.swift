import AppKit
import CoreModel
import Testing

@testable import Reel

@Suite("Timeline canvas event routing")
@MainActor
struct TimelineCanvasEventRoutingTests {
    private struct MoveInvocation: Equatable {
        var itemID: ItemID
        var trackID: TrackID
        var timelineStart: RationalTime
    }

    private enum EventCreationError: Error {
        case unavailable
    }

    @Test("A clip no wider than twenty points still starts a move from its center")
    func shortClipCenterStartsMove() throws {
        let item = makeItem(duration: 1, timelineStart: 1)
        let track = Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item])
        let width: CGFloat = 200
        let projectDuration = 10.0
        let (canvas, window) = makeCanvas(
            width: width,
            timeline: Timeline(videoTracks: [track]),
            duration: projectDuration
        )
        defer { window.close() }
        let clipRect = try #require(canvas.mediaRect(for: item.id))
        #expect(clipRect.width <= 20)
        var moves: [MoveInvocation] = []
        var trims: [(ItemID, TimeRange)] = []
        canvas.assetDurations[item.assetID] = RationalTime(seconds: 10)
        canvas.canMove = { _, _, _ in true }
        canvas.onMove = {
            moves.append(MoveInvocation(itemID: $0, trackID: $1, timelineStart: $2))
        }
        canvas.onTrim = { trims.append(($0, $1)) }

        try drag(
            canvas,
            from: NSPoint(x: clipRect.midX, y: clipRect.midY),
            to: NSPoint(x: clipRect.midX + clipRect.width, y: clipRect.midY)
        )

        #expect(trims.isEmpty)
        #expect(moves.count == 1)
        #expect(moves.first?.itemID == item.id)
        #expect(moves.first?.trackID == track.id)
        #expect(moves.first?.timelineStart == RationalTime(seconds: 2))
    }

    @Test("A horizontal drag reports the later explicit timeline time")
    func horizontalDragReportsLaterTime() throws {
        let item = makeItem(duration: 1, timelineStart: 1)
        let track = Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item])
        let width: CGFloat = 546
        let projectDuration = 10.0
        let (canvas, window) = makeCanvas(
            width: width,
            timeline: Timeline(videoTracks: [track]),
            duration: projectDuration
        )
        defer { window.close() }
        let clipRect = try #require(canvas.mediaRect(for: item.id))
        #expect(clipRect.width > 20)
        var moves: [MoveInvocation] = []
        canvas.canMove = { _, _, _ in true }
        canvas.onMove = {
            moves.append(MoveInvocation(itemID: $0, trackID: $1, timelineStart: $2))
        }

        try drag(
            canvas,
            from: NSPoint(x: clipRect.midX, y: clipRect.midY),
            to: NSPoint(x: clipRect.midX + clipRect.width * 2, y: clipRect.midY)
        )

        #expect(
            moves == [
                MoveInvocation(
                    itemID: item.id,
                    trackID: track.id,
                    timelineStart: RationalTime(seconds: 3)
                )
            ])
    }

    @Test("A vertical drag routes video to the nearest compatible track")
    func verticalDragRoutesAcrossVideoTracks() throws {
        let item = makeItem(duration: 1, timelineStart: 1)
        let sourceTrack = Track(
            id: TrackID(rawValue: "v1"),
            name: "V1",
            items: [item]
        )
        let destinationTrack = Track(id: TrackID(rawValue: "v2"), name: "V2")
        let width: CGFloat = 546
        let projectDuration = 10.0
        let (canvas, window) = makeCanvas(
            width: width,
            timeline: Timeline(videoTracks: [sourceTrack, destinationTrack]),
            duration: projectDuration
        )
        defer { window.close() }
        let sourceRect = try #require(canvas.mediaRect(for: item.id))
        let destinationY = try #require(canvas.laneCenterY(for: destinationTrack.id))
        var moves: [MoveInvocation] = []
        canvas.canMove = { _, _, _ in true }
        canvas.onMove = {
            moves.append(MoveInvocation(itemID: $0, trackID: $1, timelineStart: $2))
        }

        try drag(
            canvas,
            from: NSPoint(x: sourceRect.midX, y: sourceRect.midY),
            to: NSPoint(x: sourceRect.midX + sourceRect.width, y: destinationY)
        )

        #expect(
            moves == [
                MoveInvocation(
                    itemID: item.id,
                    trackID: destinationTrack.id,
                    timelineStart: RationalTime(seconds: 2)
                )
            ])
    }

    @Test("Drag rendering keeps one stable card and a source placeholder")
    func dragRenderingIsStableAcrossTracks() throws {
        let item = makeItem(duration: 1, timelineStart: 1)
        let sourceTrack = Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item])
        let destinationTrack = Track(id: TrackID(rawValue: "v2"), name: "V2")
        let (canvas, window) = makeCanvas(
            width: 546,
            timeline: Timeline(videoTracks: [sourceTrack, destinationTrack]),
            duration: 10
        )
        defer { window.close() }
        let sourceRect = try #require(canvas.mediaRect(for: item.id))
        let destinationY = try #require(canvas.laneCenterY(for: destinationTrack.id))
        var moves: [MoveInvocation] = []
        canvas.canMove = { _, _, _ in true }
        canvas.onMove = {
            moves.append(MoveInvocation(itemID: $0, trackID: $1, timelineStart: $2))
        }

        canvas.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: sourceRect.center, in: canvas, timestamp: 0)
        )
        canvas.mouseDragged(
            with: try mouseEvent(
                .leftMouseDragged,
                at: NSPoint(x: sourceRect.midX + sourceRect.width * 2, y: destinationY),
                in: canvas,
                timestamp: 1
            )
        )

        let snapshot = try #require(canvas.moveRenderSnapshot())
        #expect(canvas.mediaRenderRole(for: item.id) == .moveSourcePlaceholder)
        #expect(snapshot.sourceRect == sourceRect)
        #expect(snapshot.previewRect.width == sourceRect.insetBy(dx: 1, dy: 0).width)
        #expect(snapshot.previewRect.height == sourceRect.height)
        #expect(snapshot.previewRect.midY == destinationY)
        #expect(snapshot.destinationTrackID == destinationTrack.id)
        #expect(snapshot.isValid)
        #expect(moves.isEmpty)

        canvas.mouseUp(
            with: try mouseEvent(
                .leftMouseUp,
                at: NSPoint(x: sourceRect.midX + sourceRect.width * 2, y: destinationY),
                in: canvas,
                timestamp: 2
            )
        )
        #expect(canvas.mediaRenderRole(for: item.id) == .normal)
        #expect(canvas.moveRenderSnapshot() == nil)
        #expect(moves.count == 1)
    }

    @Test("Drag preview and drop stay fully inside the editable horizon")
    func dragRenderingIsContainedAtRightEdge() throws {
        let item = makeItem(duration: 1, timelineStart: 1)
        let track = Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item])
        let (canvas, window) = makeCanvas(
            width: 546,
            timeline: Timeline(videoTracks: [track]),
            duration: 2
        )
        defer { window.close() }
        canvas.fixedPointsPerSecond = 25
        let sourceRect = try #require(canvas.mediaRect(for: item.id))
        var moves: [MoveInvocation] = []
        canvas.canMove = { _, _, _ in true }
        canvas.onMove = {
            moves.append(MoveInvocation(itemID: $0, trackID: $1, timelineStart: $2))
        }
        let outside = NSPoint(x: canvas.bounds.maxX + 200, y: sourceRect.midY)

        canvas.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: sourceRect.center, in: canvas, timestamp: 0)
        )
        canvas.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, at: outside, in: canvas, timestamp: 1)
        )

        let snapshot = try #require(canvas.moveRenderSnapshot())
        #expect(snapshot.previewRect.maxX <= canvas.bounds.maxX)

        canvas.mouseUp(
            with: try mouseEvent(.leftMouseUp, at: outside, in: canvas, timestamp: 2)
        )
        #expect(moves.first?.timelineStart == RationalTime(seconds: 19))
    }

    @Test("A duration change expands the canvas without rescaling clip geometry")
    func durationChangeKeepsEstablishedScale() throws {
        let item = makeItem(duration: 2, timelineStart: 3)
        let track = Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item])
        let (canvas, window) = makeCanvas(
            width: 546,
            timeline: Timeline(videoTracks: [track]),
            duration: 10
        )
        defer { window.close() }
        canvas.fixedPointsPerSecond = 25
        let before = try #require(canvas.mediaRect(for: item.id))

        canvas.duration = RationalTime(seconds: 20)
        canvas.frame.size.width = 796
        let after = try #require(canvas.mediaRect(for: item.id))

        #expect(after.minX == before.minX)
        #expect(after.width == before.width)
    }

    private func makeCanvas(
        width: CGFloat,
        timeline: Timeline,
        duration: Double
    ) -> (TimelineCanvas, NSWindow) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: width, height: 160)
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let canvas = TimelineCanvas(frame: frame)
        window.contentView = canvas
        canvas.frame = frame
        canvas.timeline = timeline
        canvas.duration = RationalTime(seconds: duration)
        canvas.isSnappingEnabled = false
        return (canvas, window)
    }

    private func drag(_ canvas: TimelineCanvas, from start: NSPoint, to end: NSPoint) throws {
        canvas.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: start, in: canvas, timestamp: 0)
        )
        canvas.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, at: end, in: canvas, timestamp: 1)
        )
        canvas.mouseUp(
            with: try mouseEvent(.leftMouseUp, at: end, in: canvas, timestamp: 2)
        )
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in canvas: TimelineCanvas,
        timestamp: TimeInterval
    ) throws -> NSEvent {
        guard
            let event = NSEvent.mouseEvent(
                with: type,
                location: canvas.convert(point, to: nil),
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: canvas.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        else { throw EventCreationError.unavailable }
        return event
    }

    private func makeItem(duration: Double, timelineStart: Double) -> TimelineItem {
        TimelineItem(
            id: ItemID(rawValue: "clip"),
            assetID: AssetID(rawValue: "asset"),
            sourceRange: TimeRange(
                start: .zero,
                duration: RationalTime(seconds: duration)
            ),
            timelineStart: RationalTime(seconds: timelineStart)
        )
    }
}

extension NSRect {
    fileprivate var center: NSPoint { NSPoint(x: midX, y: midY) }
}
