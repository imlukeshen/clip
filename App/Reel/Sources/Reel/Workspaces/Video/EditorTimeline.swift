import AppKit
import CoreModel
import ReelAppCore
import SwiftUI

struct EditorTimeline: NSViewRepresentable {
    let timeline: Timeline
    let names: [AssetID: String]
    let assetDurations: [AssetID: RationalTime]
    let audioAssetIDs: Set<AssetID>
    let missingAssetIDs: Set<AssetID>
    let selection: Set<ItemID>
    let playhead: RationalTime
    let duration: RationalTime
    let inPoint: RationalTime?
    let outPoint: RationalTime?
    let clickMarkers: [TimelineClickMarker]
    let isSnappingEnabled: Bool
    let activeTool: TimelineTool
    let targetedVideoTrackID: TrackID?
    let targetedAudioTrackID: TrackID?
    let targetedTrackKind: TrackKind
    let accent: NSColor
    let accentDim: NSColor
    let surface: NSColor
    let clip: NSColor
    let line: NSColor
    let textPrimary: NSColor
    let textTertiary: NSColor
    let audio: NSColor
    let click: NSColor
    let caption: NSColor
    let playheadColor: NSColor
    let clipCornerRadius: CGFloat
    let onSelect: (ItemID, Bool) -> Void
    let onSeek: (RationalTime, Bool) -> Void
    let onScrubbing: (Bool) -> Void
    let onTargetTrack: (TrackID) -> Void
    let canMove: (ItemID, TrackID, RationalTime) -> Bool
    let onMove: (ItemID, TrackID, RationalTime) -> Void
    let onTrim: (ItemID, TimeRange) -> Void
    let onRazor: (ItemID, RationalTime) -> Void
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> TimelineCanvas {
        let view = TimelineCanvas()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityHelp(
            "Drag media between compatible tracks without moving neighbouring clips. Select a lane label to target that track."
        )
        return view
    }

    func updateNSView(_ view: TimelineCanvas, context: Context) {
        view.timeline = timeline
        view.names = names
        view.assetDurations = assetDurations
        view.audioAssetIDs = audioAssetIDs
        view.missingAssetIDs = missingAssetIDs
        view.selection = selection
        view.playhead = playhead
        view.duration = duration
        view.inPoint = inPoint
        view.outPoint = outPoint
        view.clickMarkers = clickMarkers
        view.isSnappingEnabled = isSnappingEnabled
        view.activeTool = activeTool
        view.targetedVideoTrackID = targetedVideoTrackID
        view.targetedAudioTrackID = targetedAudioTrackID
        view.targetedTrackKind = targetedTrackKind
        view.accent = accent
        view.accentDim = accentDim
        view.surface = surface
        view.clipColor = clip
        view.lineColor = line
        view.textPrimary = textPrimary
        view.textTertiary = textTertiary
        view.audioColor = audio
        view.clickColor = click
        view.captionColor = caption
        view.playheadColor = playheadColor
        view.clipCornerRadius = clipCornerRadius
        view.onSelect = onSelect
        view.onSeek = onSeek
        view.onScrubbing = onScrubbing
        view.onTargetTrack = onTargetTrack
        view.canMove = canMove
        view.onMove = onMove
        view.onTrim = onTrim
        view.onRazor = onRazor
        view.onZoom = onZoom
        view.needsDisplay = true
    }
}

final class TimelineCanvas: NSView {
    var timeline = Timeline()
    var names: [AssetID: String] = [:]
    var assetDurations: [AssetID: RationalTime] = [:]
    var audioAssetIDs: Set<AssetID> = []
    var missingAssetIDs: Set<AssetID> = []
    var selection: Set<ItemID> = []
    var playhead = RationalTime.zero
    var duration = RationalTime.zero
    var inPoint: RationalTime?
    var outPoint: RationalTime?
    var clickMarkers: [TimelineClickMarker] = []
    var isSnappingEnabled = true
    var activeTool = TimelineTool.select
    var targetedVideoTrackID: TrackID?
    var targetedAudioTrackID: TrackID?
    var targetedTrackKind = TrackKind.video
    var accent = NSColor.white
    var accentDim = NSColor.white.withAlphaComponent(0.16)
    var surface = NSColor.black
    var clipColor = NSColor.darkGray
    var lineColor = NSColor.gray
    var textPrimary = NSColor.white
    var textTertiary = NSColor.lightGray
    var audioColor = NSColor.green
    var clickColor = NSColor.orange
    var captionColor = NSColor.white
    var playheadColor = NSColor.red
    /// Corner radius for clip rectangles, supplied from the theme so the
    /// timeline rounds in step with the rest of the app.
    var clipCornerRadius: CGFloat = 5
    var onSelect: ((ItemID, Bool) -> Void)?
    var onSeek: ((RationalTime, Bool) -> Void)?
    var onScrubbing: ((Bool) -> Void)?
    var onTargetTrack: ((TrackID) -> Void)?
    var canMove: ((ItemID, TrackID, RationalTime) -> Bool)?
    var onMove: ((ItemID, TrackID, RationalTime) -> Void)?
    var onTrim: ((ItemID, TimeRange) -> Void)?
    var onRazor: ((ItemID, RationalTime) -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    private let labelWidth: CGFloat = 46
    private let rulerHeight: CGFloat = 24
    private let videoHeight: CGFloat = 34
    private let audioHeight: CGFloat = 26
    private let eventHeight: CGFloat = 11
    private let laneGap: CGFloat = 6
    private var gesture: Gesture?
    private var previewRange: (ItemID, TimeRange)?
    private var movePreview: MovePreview?
    private var snapIndicator: RationalTime?
    private var hoveredItemID: ItemID?
    private var hoveredEdge: Edge?
    private var hoveredTime: RationalTime?
    private var trackingArea: NSTrackingArea?
    private var pendingSeek: RationalTime?
    private var seekIsScheduled = false
    private var accessibilitySnapshot: AccessibilitySnapshot?

    private struct AccessibilitySnapshot: Equatable {
        var timeline: Timeline
        var names: [AssetID: String]
        var clickMarkers: [TimelineClickMarker]
        var targetedVideoTrackID: TrackID?
        var targetedAudioTrackID: TrackID?
        var targetedTrackKind: TrackKind
        var bounds: CGRect
        var pointsPerSecond: CGFloat
    }

    private enum Gesture {
        case scrub
        case move(
            itemID: ItemID,
            kind: TrackKind,
            sourceTrackIndex: Int,
            originalStart: RationalTime,
            grabOffset: RationalTime
        )
        case trim(
            itemID: ItemID,
            edge: Edge,
            original: TimeRange,
            speed: Double,
            originX: CGFloat
        )
    }

    private struct ItemRect {
        var item: TimelineItem
        var index: Int
        var trackIndex: Int
        var kind: TrackKind
        var trackName: String
        var rect: NSRect
    }

    private struct MovePreview {
        var itemID: ItemID
        var kind: TrackKind
        var trackIndex: Int
        var trackID: TrackID
        var timelineStart: RationalTime
        var duration: RationalTime
        var isValid: Bool
    }

    private enum Edge: Equatable { case leading, trailing }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        surface.setFill()
        bounds.fill()
        drawRuler()
        drawTargetedLanes()
        drawLaneLabels()
        drawVideo()
        drawAudio()
        drawClicks()
        drawCaptions()
        drawProjectMarkers()
        drawInOutPoints()
        drawMovePreview()
        drawSnapGuide()
        drawHoverGuide()
        drawPlayhead()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if point.x < labelWidth, let trackID = laneTrack(at: point) {
            onTargetTrack?(trackID)
            return
        }
        if let hit = mediaItem(at: point) {
            onSelect?(hit.item.id, event.modifierFlags.contains(.shift))
            onSeek?(time(at: point.x), true)
            if activeTool == .razor {
                onRazor?(hit.item.id, time(at: point.x))
                return
            }
            if abs(point.x - hit.rect.minX) <= 10 {
                gesture = .trim(
                    itemID: hit.item.id,
                    edge: .leading,
                    original: hit.item.sourceRange,
                    speed: hit.item.speed,
                    originX: point.x
                )
            } else if abs(point.x - hit.rect.maxX) <= 10 {
                gesture = .trim(
                    itemID: hit.item.id,
                    edge: .trailing,
                    original: hit.item.sourceRange,
                    speed: hit.item.speed,
                    originX: point.x
                )
            } else {
                gesture = .move(
                    itemID: hit.item.id,
                    kind: hit.kind,
                    sourceTrackIndex: hit.trackIndex,
                    originalStart: hit.item.timelineStart,
                    grabOffset: RationalTime(
                        seconds: max((point.x - hit.rect.minX) / pointsPerSecond, 0)
                    )
                )
                movePreview = MovePreview(
                    itemID: hit.item.id,
                    kind: hit.kind,
                    trackIndex: hit.trackIndex,
                    trackID: track(for: hit.kind, at: hit.trackIndex).id,
                    timelineStart: hit.item.timelineStart,
                    duration: hit.item.timelineDuration,
                    isValid: true
                )
                NSCursor.closedHand.set()
            }
        } else {
            gesture = .scrub
            onScrubbing?(true)
            onSeek?(time(at: point.x), false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoveredTime = time(at: point.x)
        switch gesture {
        case .scrub:
            scheduleSeek(to: time(at: point.x))
        case .move(let itemID, let kind, _, _, let grabOffset):
            autoscroll(with: event)
            let currentPoint = convert(event.locationInWindow, from: nil)
            movePreview = proposedMove(
                itemID: itemID,
                kind: kind,
                point: currentPoint,
                grabOffset: grabOffset
            )
            needsDisplay = true
        case .trim(let itemID, let edge, let original, let speed, let originX):
            var sourceDelta = RationalTime(
                seconds: (point.x - originX) / pointsPerSecond * speed
            )
            let minimum = RationalTime(seconds: 0.1)
            guard
                let item = (timeline.videoTracks + timeline.audioTracks).lazy
                    .flatMap(\.items).first(where: {
                        $0.id == itemID
                    }),
                let assetDuration = assetDurations[item.assetID]
            else { return }
            if isSnappingEnabled {
                let timelineDelta = sourceDelta.scaled(by: 1 / speed)
                let proposed =
                    edge == .leading
                    ? item.timelineStart + timelineDelta
                    : item.timelineEnd + timelineDelta
                let ownEdge =
                    edge == .leading
                    ? "\(item.id.rawValue)-start" : "\(item.id.rawValue)-end"
                let result = SnapEngine.snap(
                    proposed,
                    to: SnapEngine.points(
                        in: timeline,
                        playhead: playhead,
                        clickTimes: clickMarkers.map(\.timelineTime)
                    ),
                    threshold: RationalTime(seconds: Double(8 / pointsPerSecond)),
                    excludingIDs: [ownEdge]
                )
                snapIndicator = result.point?.time
                let base = edge == .leading ? item.timelineStart : item.timelineEnd
                sourceDelta = (result.time - base).scaled(by: speed)
            } else {
                snapIndicator = nil
            }
            switch edge {
            case .leading:
                let delta = min(
                    max(sourceDelta, .zero - original.start),
                    original.duration - minimum
                )
                previewRange = (
                    itemID,
                    TimeRange(
                        start: original.start + delta,
                        duration: original.duration - delta
                    )
                )
            case .trailing:
                let maximum = assetDuration - original.start
                let nextDuration = min(max(original.duration + sourceDelta, minimum), maximum)
                previewRange = (
                    itemID,
                    TimeRange(start: original.start, duration: nextDuration)
                )
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            previewRange = nil
            movePreview = nil
            snapIndicator = nil
            NSCursor.arrow.set()
            needsDisplay = true
        }
        guard let gesture else { return }
        switch gesture {
        case .scrub:
            let point = convert(event.locationInWindow, from: nil)
            pendingSeek = nil
            onSeek?(time(at: point.x), true)
            onScrubbing?(false)
        case .move(
            let itemID,
            _,
            let sourceTrackIndex,
            let originalStart,
            _
        ):
            if let movePreview, movePreview.isValid {
                if movePreview.trackIndex != sourceTrackIndex
                    || movePreview.timelineStart != originalStart
                {
                    onMove?(itemID, movePreview.trackID, movePreview.timelineStart)
                }
            }
        case .trim(let itemID, _, let original, _, _):
            if let previewRange, previewRange.1 != original {
                onTrim?(itemID, previewRange.1)
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard case nil = gesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hit = mediaItem(at: point)
        hoveredTime = time(at: point.x)
        hoveredItemID = hit?.item.id
        if let hit, abs(point.x - hit.rect.minX) <= 10 {
            hoveredEdge = .leading
            NSCursor.resizeLeftRight.set()
        } else if let hit, abs(point.x - hit.rect.maxX) <= 10 {
            hoveredEdge = .trailing
            NSCursor.resizeLeftRight.set()
        } else if hit != nil {
            hoveredEdge = nil
            (activeTool == .razor ? NSCursor.crosshair : NSCursor.openHand).set()
        } else {
            hoveredEdge = nil
            (activeTool == .razor ? NSCursor.crosshair : NSCursor.arrow).set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard case nil = gesture else { return }
        hoveredItemID = nil
        hoveredEdge = nil
        hoveredTime = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(max(0.2, 1 + event.magnification))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let delta =
                event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY : event.scrollingDeltaY * 4
            onZoom?(CGFloat(exp(Double(delta) * 0.018)))
            return
        }
        super.scrollWheel(with: event)
    }

    private func scheduleSeek(to time: RationalTime) {
        pendingSeek = time
        guard !seekIsScheduled else { return }
        seekIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            seekIsScheduled = false
            guard let pendingSeek else { return }
            self.pendingSeek = nil
            self.onSeek?(pendingSeek, false)
        }
    }

    private var pointsPerSecond: CGFloat {
        max((bounds.width - labelWidth) / max(CGFloat(duration.seconds), 0.01), 1)
    }

    private var videoTrackCount: Int { max(timeline.videoTracks.count, 1) }
    private var audioTrackCount: Int { max(timeline.audioTracks.count, 1) }
    private func videoY(for trackIndex: Int) -> CGFloat {
        let displayRow = videoTrackCount - 1 - trackIndex
        return rulerHeight + 4 + CGFloat(displayRow) * (videoHeight + laneGap)
    }
    private func audioY(for trackIndex: Int) -> CGFloat {
        rulerHeight + 4 + CGFloat(videoTrackCount) * (videoHeight + laneGap)
            + CGFloat(trackIndex) * (audioHeight + laneGap)
    }
    private var clickY: CGFloat {
        audioY(for: 0) + CGFloat(audioTrackCount) * (audioHeight + laneGap)
    }
    private var captionY: CGFloat { clickY + eventHeight + laneGap }

    private func displayItems(in track: Track, trackIndex: Int) -> [TimelineItem] {
        var items = track.items.map { item in
            guard let previewRange, previewRange.0 == item.id else { return item }
            var copy = item
            copy.sourceRange = previewRange.1
            return copy
        }
        if trackIndex == 0, let previewRange,
            let previewIndex = items.firstIndex(where: { $0.id == previewRange.0 })
        {
            let original = track.items[previewIndex]
            let delta = items[previewIndex].timelineDuration - original.timelineDuration
            if previewIndex + 1 < items.count {
                for index in (previewIndex + 1)..<items.count {
                    items[index].timelineStart = items[index].timelineStart + delta
                }
            }
        }
        return items
    }

    private func videoItemRects() -> [ItemRect] {
        timeline.videoTracks.enumerated().flatMap { trackIndex, track in
            displayItems(in: track, trackIndex: trackIndex).enumerated().map { index, item in
                let width = max(CGFloat(item.timelineDuration.seconds) * pointsPerSecond, 2)
                let x = labelWidth + CGFloat(item.timelineStart.seconds) * pointsPerSecond
                return ItemRect(
                    item: item,
                    index: index,
                    trackIndex: trackIndex,
                    kind: .video,
                    trackName: track.name,
                    rect: NSRect(
                        x: x,
                        y: videoY(for: trackIndex),
                        width: width,
                        height: videoHeight
                    )
                )
            }
        }
    }

    private func audioItemRects() -> [ItemRect] {
        timeline.audioTracks.enumerated().flatMap { trackIndex, track in
            displayItems(in: track, trackIndex: trackIndex).enumerated().map { index, item in
                let width = max(CGFloat(item.timelineDuration.seconds) * pointsPerSecond, 2)
                let x = labelWidth + CGFloat(item.timelineStart.seconds) * pointsPerSecond
                return ItemRect(
                    item: item,
                    index: index,
                    trackIndex: trackIndex,
                    kind: .audio,
                    trackName: track.name,
                    rect: NSRect(
                        x: x,
                        y: audioY(for: trackIndex),
                        width: width,
                        height: audioHeight
                    )
                )
            }
        }
    }

    private func mediaItem(at point: NSPoint) -> ItemRect? {
        (videoItemRects() + audioItemRects()).first {
            $0.rect.insetBy(dx: 0, dy: -2).contains(point)
        }
    }

    private func laneTrack(at point: NSPoint) -> TrackID? {
        for (index, track) in timeline.videoTracks.enumerated()
        where NSRect(
            x: 0,
            y: videoY(for: index),
            width: labelWidth,
            height: videoHeight
        ).contains(point) {
            return track.id
        }
        for (index, track) in timeline.audioTracks.enumerated()
        where NSRect(
            x: 0,
            y: audioY(for: index),
            width: labelWidth,
            height: audioHeight
        ).contains(point) {
            return track.id
        }
        return nil
    }

    private func time(at x: CGFloat) -> RationalTime {
        let seconds = min(
            max((x - labelWidth) / pointsPerSecond, 0),
            CGFloat(duration.seconds)
        )
        return RationalTime(seconds: seconds)
    }

    private func proposedMove(
        itemID: ItemID,
        kind: TrackKind,
        point: NSPoint,
        grabOffset: RationalTime
    ) -> MovePreview? {
        guard
            let item = (timeline.videoTracks + timeline.audioTracks)
                .lazy.flatMap(\.items).first(where: { $0.id == itemID })
        else { return nil }
        let trackIndex = nearestTrackIndex(to: point.y, kind: kind)
        let destination = track(for: kind, at: trackIndex)
        let rawTime = RationalTime(
            seconds: max(Double((point.x - labelWidth) / pointsPerSecond), 0)
        )
        var proposedStart = max(rawTime - grabOffset, .zero)
        snapIndicator = nil
        if isSnappingEnabled {
            let points = SnapEngine.points(
                in: timeline,
                playhead: playhead,
                clickTimes: clickMarkers.map(\.timelineTime)
            )
            var excludedIDs = Set(
                selection.flatMap { id in
                    ["\(id.rawValue)-start", "\(id.rawValue)-end"]
                })
            excludedIDs.insert("\(itemID.rawValue)-start")
            excludedIDs.insert("\(itemID.rawValue)-end")
            if let nestID = item.nestID {
                for nested in (timeline.videoTracks + timeline.audioTracks).flatMap(\.items)
                where nested.nestID == nestID {
                    excludedIDs.insert("\(nested.id.rawValue)-start")
                    excludedIDs.insert("\(nested.id.rawValue)-end")
                }
            }
            let threshold = RationalTime(seconds: Double(8 / pointsPerSecond))
            let result = TimelineMoveSnapper.snap(
                proposedStart: proposedStart,
                duration: item.timelineDuration,
                to: points,
                threshold: threshold,
                excludingIDs: excludedIDs
            )
            proposedStart = result.timelineStart
            snapIndicator = result.point?.time
        }
        return MovePreview(
            itemID: itemID,
            kind: kind,
            trackIndex: trackIndex,
            trackID: destination.id,
            timelineStart: proposedStart,
            duration: item.timelineDuration,
            isValid: canMove?(itemID, destination.id, proposedStart) ?? false
        )
    }

    private func nearestTrackIndex(to y: CGFloat, kind: TrackKind) -> Int {
        let count = kind == .video ? timeline.videoTracks.count : timeline.audioTracks.count
        guard count > 1 else { return 0 }
        return (0..<count).min { left, right in
            let leftY =
                kind == .video
                ? videoY(for: left) + videoHeight / 2
                : audioY(for: left) + audioHeight / 2
            let rightY =
                kind == .video
                ? videoY(for: right) + videoHeight / 2
                : audioY(for: right) + audioHeight / 2
            return abs(leftY - y) < abs(rightY - y)
        } ?? 0
    }

    private func track(for kind: TrackKind, at index: Int) -> Track {
        switch kind {
        case .video: timeline.videoTracks[index]
        case .audio: timeline.audioTracks[index]
        }
    }

    private func drawRuler() {
        lineColor.setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: labelWidth, y: rulerHeight),
            to: NSPoint(x: bounds.maxX, y: rulerHeight)
        )
        let interval = rulerInterval()
        guard duration > .zero else { return }
        var second = 0.0
        while second <= duration.seconds {
            let x = labelWidth + CGFloat(second) * pointsPerSecond
            NSBezierPath.strokeLine(
                from: NSPoint(x: x, y: rulerHeight - 5),
                to: NSPoint(x: x, y: rulerHeight)
            )
            drawText(formatRuler(second), at: NSPoint(x: x + 3, y: 5), color: textTertiary)
            second += interval
        }
    }

    private func drawLaneLabels() {
        for (index, track) in timeline.videoTracks.enumerated() {
            let state = track.isLocked ? "🔒" : track.isEnabled ? "" : "–"
            drawText(
                "\(track.name)\(state)",
                at: NSPoint(x: 7, y: videoY(for: index) + 9),
                color: track.id == targetedVideoTrackID && targetedTrackKind == .video
                    ? accent : textTertiary
            )
        }
        if timeline.audioTracks.isEmpty {
            drawText("A1↔", at: NSPoint(x: 8, y: audioY(for: 0) + 7), color: textTertiary)
        } else {
            for (index, track) in timeline.audioTracks.enumerated() {
                let state = track.isLocked ? "🔒" : track.isMuted ? "M" : ""
                drawText(
                    "\(track.name)\(state)",
                    at: NSPoint(x: 7, y: audioY(for: index) + 7),
                    color: track.id == targetedAudioTrackID && targetedTrackKind == .audio
                        ? accent : textTertiary
                )
            }
        }
        drawText("●", at: NSPoint(x: 17, y: clickY - 2), color: clickColor)
        drawText("CC", at: NSPoint(x: 13, y: captionY - 2), color: textTertiary)
    }

    private func drawTargetedLanes() {
        for (index, track) in timeline.videoTracks.enumerated()
        where track.id == targetedVideoTrackID && targetedTrackKind == .video {
            drawTargetedLane(y: videoY(for: index), height: videoHeight)
        }
        for (index, track) in timeline.audioTracks.enumerated()
        where track.id == targetedAudioTrackID && targetedTrackKind == .audio {
            drawTargetedLane(y: audioY(for: index), height: audioHeight)
        }
    }

    private func drawTargetedLane(y: CGFloat, height: CGFloat) {
        accent.withAlphaComponent(0.035).setFill()
        NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
        accent.setFill()
        NSRect(x: 1, y: y + 3, width: 2, height: max(height - 6, 0)).fill()
    }

    private func drawVideo() {
        for clip in videoItemRects() {
            let selected = selection.contains(clip.item.id)
            let hovered = hoveredItemID == clip.item.id
            let fillColor: NSColor
            if selected {
                fillColor = accentDim
            } else if hovered {
                fillColor = clipColor.blended(withFraction: 0.12, of: accent) ?? clipColor
            } else {
                fillColor = clipColor
            }
            let path = NSBezierPath(
                roundedRect: clip.rect.insetBy(dx: 1, dy: 0),
                xRadius: clipCornerRadius,
                yRadius: clipCornerRadius
            )
            fillColor.setFill()
            path.fill()
            (selected || hovered ? accent : lineColor).setStroke()
            path.lineWidth = selected ? 1.5 : hovered ? 1 : 0.5
            path.stroke()

            if missingAssetIDs.contains(clip.item.assetID) {
                drawMissingHatch(in: clip.rect.insetBy(dx: 1, dy: 0))
            }

            let title = names[clip.item.assetID] ?? "Clip \(clip.index + 1)"
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip.rect.insetBy(dx: 7, dy: 2)).addClip()
            drawText(
                title,
                at: NSPoint(x: clip.rect.minX + 8, y: clip.rect.minY + 8),
                color: textPrimary
            )
            NSGraphicsContext.restoreGraphicsState()

            if clip.item.nestID != nil, clip.rect.width > 58 {
                drawText(
                    "NEST",
                    at: NSPoint(x: clip.rect.maxX - 34, y: clip.rect.minY + 8),
                    color: textTertiary
                )
            }

            for (effectIndex, effect) in clip.item.effects.enumerated() {
                let x =
                    clip.rect.minX + CGFloat(effect.range.start.seconds / clip.item.speed)
                    * pointsPerSecond
                let width = max(
                    CGFloat(effect.range.duration.seconds / clip.item.speed) * pointsPerSecond, 2)
                let visibleWidth = max(0, min(width, clip.rect.maxX - x))
                guard visibleWidth > 0 else { continue }
                effectColor(effect.kind).setFill()
                NSRect(
                    x: x,
                    y: clip.rect.maxY - 3 - CGFloat(effectIndex % 2) * 3,
                    width: visibleWidth,
                    height: 2
                ).fill()
            }

            if selected {
                accent.setFill()
                NSRect(x: clip.rect.minX, y: clip.rect.minY + 4, width: 3, height: 26).fill()
                NSRect(x: clip.rect.maxX - 3, y: clip.rect.minY + 4, width: 3, height: 26).fill()
            }

            if hovered, let hoveredEdge {
                accent.setFill()
                let edgeX = hoveredEdge == .leading ? clip.rect.minX : clip.rect.maxX - 4
                NSBezierPath(
                    roundedRect: NSRect(
                        x: edgeX,
                        y: clip.rect.minY + 3,
                        width: 4,
                        height: clip.rect.height - 6
                    ),
                    xRadius: 2,
                    yRadius: 2
                ).fill()
            }
        }
    }

    private func drawMissingHatch(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        textTertiary.withAlphaComponent(0.45).setStroke()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            path.lineWidth = 1
            path.stroke()
            x += 8
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawAudio() {
        let explicitAudio = !timeline.audioTracks.isEmpty
        let items: [ItemRect]
        if explicitAudio {
            items = audioItemRects()
        } else {
            items = videoItemRects().filter { audioAssetIDs.contains($0.item.assetID) }
                .map { video in
                    var linked = video
                    linked.kind = .audio
                    linked.trackIndex = 0
                    linked.trackName = "A1 linked"
                    linked.rect = NSRect(
                        x: video.rect.minX,
                        y: audioY(for: 0),
                        width: video.rect.width,
                        height: audioHeight
                    )
                    return linked
                }
        }
        for media in items {
            let rect = media.rect.insetBy(dx: 1, dy: 0)
            let selected = explicitAudio && selection.contains(media.item.id)
            let hovered = explicitAudio && hoveredItemID == media.item.id
            (selected ? accentDim : audioColor.withAlphaComponent(0.13)).setFill()
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: clipCornerRadius,
                yRadius: clipCornerRadius
            )
            path.fill()
            (selected || hovered ? accent : audioColor.withAlphaComponent(0.42)).setStroke()
            path.lineWidth = selected ? 1.5 : 0.7
            path.stroke()

            audioColor.withAlphaComponent(0.42).setStroke()
            let wave = NSBezierPath()
            var x = rect.minX + 2
            while x < rect.maxX - 2 {
                let amplitude = 2 + abs(sin(x * 0.13)) * 4
                wave.move(to: NSPoint(x: x, y: rect.midY - amplitude))
                wave.line(to: NSPoint(x: x, y: rect.midY + amplitude))
                x += 4
            }
            wave.stroke()

            if explicitAudio {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect.insetBy(dx: 7, dy: 2)).addClip()
                drawText(
                    names[media.item.assetID] ?? "Audio",
                    at: NSPoint(x: rect.minX + 8, y: rect.minY + 6),
                    color: textPrimary
                )
                NSGraphicsContext.restoreGraphicsState()
                if selected {
                    accent.setFill()
                    NSRect(x: rect.minX, y: rect.minY + 3, width: 3, height: rect.height - 6)
                        .fill()
                    NSRect(x: rect.maxX - 3, y: rect.minY + 3, width: 3, height: rect.height - 6)
                        .fill()
                }
            }
        }
    }

    private func drawClicks() {
        clickColor.setFill()
        for marker in clickMarkers {
            let x = labelWidth + CGFloat(marker.timelineTime.seconds) * pointsPerSecond
            NSRect(x: x - 1, y: clickY, width: 2, height: eventHeight).fill()
        }
        refreshAccessibilityChildren()
    }

    private func refreshAccessibilityChildren() {
        let snapshot = AccessibilitySnapshot(
            timeline: timeline,
            names: names,
            clickMarkers: clickMarkers,
            targetedVideoTrackID: targetedVideoTrackID,
            targetedAudioTrackID: targetedAudioTrackID,
            targetedTrackKind: targetedTrackKind,
            bounds: bounds,
            pointsPerSecond: pointsPerSecond
        )
        guard snapshot != accessibilitySnapshot else { return }
        accessibilitySnapshot = snapshot
        let videoTrackChildren = timeline.videoTracks.enumerated().map {
            index, track -> NSAccessibilityElement in
            trackAccessibilityElement(
                track,
                kind: "video",
                isTargeted: track.id == targetedVideoTrackID,
                rect: NSRect(
                    x: 0,
                    y: videoY(for: index),
                    width: labelWidth,
                    height: videoHeight
                )
            )
        }
        let audioTrackChildren = timeline.audioTracks.enumerated().map {
            index, track -> NSAccessibilityElement in
            trackAccessibilityElement(
                track,
                kind: "audio",
                isTargeted: track.id == targetedAudioTrackID,
                rect: NSRect(
                    x: 0,
                    y: audioY(for: index),
                    width: labelWidth,
                    height: audioHeight
                )
            )
        }
        let mediaChildren = (videoItemRects() + audioItemRects()).map {
            media -> NSAccessibilityElement in
            let element = TimelinePressAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            let kind = media.kind == .video ? "video" : "audio"
            element.setAccessibilityLabel(
                "\(media.trackName) \(kind): \(names[media.item.assetID] ?? "Media")"
            )
            element.setAccessibilityValue(
                "\(formatClickTime(media.item.timelineStart.seconds)), \(formatClickTime(media.item.timelineDuration.seconds)) long"
            )
            element.setAccessibilityIdentifier("timeline-item-\(media.item.id.rawValue)")
            element.onPress = { [weak self] in self?.onSelect?(media.item.id, false) }
            if let window {
                element.setAccessibilityFrame(
                    window.convertToScreen(convert(media.rect, to: nil))
                )
            }
            return element
        }
        let clickChildren = clickMarkers.map { marker -> NSAccessibilityElement in
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel("Recorded click")
            element.setAccessibilityValue(formatClickTime(marker.timelineTime.seconds))
            element.setAccessibilityIdentifier(marker.id)
            return element
        }
        setAccessibilityChildren(
            videoTrackChildren + audioTrackChildren + mediaChildren + clickChildren
        )
    }

    private func trackAccessibilityElement(
        _ track: Track,
        kind: String,
        isTargeted: Bool,
        rect: NSRect
    ) -> NSAccessibilityElement {
        let element = TimelinePressAccessibilityElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.button)
        element.setAccessibilityLabel("\(track.name) \(kind) track")
        element.setAccessibilityHelp("Press to target this track for inserts and edits.")
        element.onPress = { [weak self] in self?.onTargetTrack?(track.id) }
        let states = [
            isTargeted ? "targeted" : nil,
            track.isLocked ? "locked" : nil,
            track.isMuted ? "muted" : nil,
            track.isSolo ? "solo" : nil,
            track.isEnabled ? nil : "disabled",
        ].compactMap { $0 }
        element.setAccessibilityValue(states.isEmpty ? "available" : states.joined(separator: ", "))
        element.setAccessibilityIdentifier("timeline-track-\(track.id.rawValue)")
        if let window {
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
        }
        return element
    }

    private func formatClickTime(_ seconds: Double) -> String {
        String(
            format: "%02d:%02d.%03d",
            Int(seconds) / 60,
            Int(seconds) % 60,
            Int(seconds * 1_000) % 1_000
        )
    }

    private func drawCaptions() {
        for caption in timeline.captions {
            let rect = NSRect(
                x: labelWidth + CGFloat(caption.range.start.seconds) * pointsPerSecond,
                y: captionY,
                width: max(CGFloat(caption.range.duration.seconds) * pointsPerSecond, 2),
                height: eventHeight
            )
            captionColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawProjectMarkers() {
        for projectMarker in timeline.markers {
            let x = labelWidth + CGFloat(projectMarker.time.seconds) * pointsPerSecond
            NSColor(
                calibratedRed: CGFloat(projectMarker.color.r),
                green: CGFloat(projectMarker.color.g),
                blue: CGFloat(projectMarker.color.b),
                alpha: CGFloat(projectMarker.color.a)
            ).setFill()
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: x - 4, y: rulerHeight - 8))
            marker.line(to: NSPoint(x: x + 4, y: rulerHeight - 8))
            marker.line(to: NSPoint(x: x, y: rulerHeight - 1))
            marker.close()
            marker.fill()
        }
    }

    private func drawInOutPoints() {
        for (point, color) in [(inPoint, audioColor), (outPoint, playheadColor)] {
            guard let point else { continue }
            let x = labelWidth + CGFloat(point.seconds) * pointsPerSecond
            color.withAlphaComponent(0.8).setFill()
            NSRect(x: x - 0.5, y: rulerHeight, width: 1, height: bounds.maxY - rulerHeight)
                .fill()
        }
    }

    private func drawSnapGuide() {
        guard let snapIndicator else { return }
        let x = labelWidth + CGFloat(snapIndicator.seconds) * pointsPerSecond
        accent.withAlphaComponent(0.9).setFill()
        NSRect(x: x - 0.5, y: rulerHeight, width: 1, height: bounds.maxY - rulerHeight).fill()

        let label = "Snap \(formatHoverTime(snapIndicator.seconds))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: surface,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let labelX = min(max(x - size.width / 2 - 5, labelWidth + 3), bounds.maxX - size.width - 13)
        let rect = NSRect(x: labelX, y: rulerHeight + 3, width: size.width + 10, height: 17)
        accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(
            at: NSPoint(x: rect.minX + 5, y: rect.minY + 2),
            withAttributes: attributes
        )
    }

    private func drawHoverGuide() {
        guard let hoveredTime, case nil = gesture else { return }
        let x = labelWidth + CGFloat(hoveredTime.seconds) * pointsPerSecond
        textTertiary.withAlphaComponent(0.3).setFill()
        NSRect(
            x: x - 0.5,
            y: rulerHeight,
            width: 1,
            height: captionY + eventHeight - rulerHeight
        ).fill()

        let label = formatHoverTime(hoveredTime.seconds)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: textPrimary,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let labelX = min(max(x + 5, labelWidth + 3), bounds.maxX - size.width - 11)
        let rect = NSRect(x: labelX, y: 3, width: size.width + 8, height: 16)
        clipColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(
            at: NSPoint(x: rect.minX + 4, y: rect.minY + 2),
            withAttributes: attributes
        )
    }

    private func drawMovePreview() {
        guard let preview = movePreview else { return }
        let color = preview.isValid ? accent : playheadColor
        let laneY =
            preview.kind == .video
            ? videoY(for: preview.trackIndex) : audioY(for: preview.trackIndex)
        let laneHeight = preview.kind == .video ? videoHeight : audioHeight
        color.withAlphaComponent(0.06).setFill()
        NSRect(
            x: labelWidth,
            y: laneY - 2,
            width: max(bounds.maxX - labelWidth, 0),
            height: laneHeight + 4
        ).fill()

        let rect = NSRect(
            x: labelWidth + CGFloat(preview.timelineStart.seconds) * pointsPerSecond,
            y: laneY,
            width: max(CGFloat(preview.duration.seconds) * pointsPerSecond, 2),
            height: laneHeight
        ).insetBy(dx: 1, dy: 0)
        color.withAlphaComponent(preview.isValid ? 0.28 : 0.16).setFill()
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: clipCornerRadius,
            yRadius: clipCornerRadius
        )
        path.fill()
        color.setStroke()
        path.lineWidth = 2
        path.setLineDash([6, 3], count: 2, phase: 0)
        path.stroke()

        let trackName = track(for: preview.kind, at: preview.trackIndex).name
        let status: String
        if !preview.isValid {
            status = "Can't place media here"
        } else {
            status = "\(trackName)  \(formatHoverTime(preview.timelineStart.seconds))"
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: 7, dy: 2)).addClip()
        drawText(
            status,
            at: NSPoint(x: rect.minX + 8, y: rect.minY + max((rect.height - 12) / 2, 2)),
            color: textPrimary
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPlayhead() {
        let x = labelWidth + CGFloat(playhead.seconds) * pointsPerSecond
        playheadColor.setFill()
        NSRect(
            x: x - 0.5, y: rulerHeight - 1, width: 1,
            height: captionY + eventHeight - rulerHeight + 2
        ).fill()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: x - 4, y: rulerHeight - 6))
        marker.line(to: NSPoint(x: x + 4, y: rulerHeight - 6))
        marker.line(to: NSPoint(x: x, y: rulerHeight))
        marker.close()
        marker.fill()
    }

    private func drawText(_ text: String, at point: NSPoint, color: NSColor) {
        (text as NSString).draw(
            at: point,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: color,
            ]
        )
    }

    private func effectColor(_ kind: EffectKind) -> NSColor {
        switch kind {
        case .zoom: accent
        case .crop: accent
        case .background: audioColor
        case .blur: playheadColor
        case .cursor: clickColor
        case .text: captionColor
        case .unknown: textTertiary
        }
    }

    private func rulerInterval() -> Double {
        switch pointsPerSecond {
        case 80...: 1
        case 30...: 2
        case 12...: 5
        default: 10
        }
    }

    private func formatRuler(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func formatHoverTime(_ seconds: Double) -> String {
        String(
            format: "%02d:%02d.%03d",
            Int(seconds) / 60,
            Int(seconds) % 60,
            Int(seconds * 1_000) % 1_000
        )
    }
}

private final class TimelinePressAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}
