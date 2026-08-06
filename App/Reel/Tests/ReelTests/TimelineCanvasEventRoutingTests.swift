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
