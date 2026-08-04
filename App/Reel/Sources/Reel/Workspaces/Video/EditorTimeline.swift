import AppKit
import CoreModel
import ReelAppCore
import SwiftUI

struct EditorTimeline: NSViewRepresentable {
    let timeline: Timeline
    let names: [AssetID: String]
    let assetDurations: [AssetID: RationalTime]
    let missingAssetIDs: Set<AssetID>
    let selection: Set<ItemID>
    let playhead: RationalTime
    let duration: RationalTime
    let inPoint: RationalTime?
    let outPoint: RationalTime?
    let clickMarkers: [TimelineClickMarker]
    let isSnappingEnabled: Bool
    let activeTool: TimelineTool
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
    let onReorder: (ItemID, Int) -> Void
    let onTrim: (ItemID, TimeRange) -> Void
    let onRazor: (ItemID, RationalTime) -> Void
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> TimelineCanvas {
        let view = TimelineCanvas()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        return view
    }

    func updateNSView(_ view: TimelineCanvas, context: Context) {
        view.timeline = timeline
        view.names = names
        view.assetDurations = assetDurations
        view.missingAssetIDs = missingAssetIDs
        view.selection = selection
        view.playhead = playhead
        view.duration = duration
        view.inPoint = inPoint
        view.outPoint = outPoint
        view.clickMarkers = clickMarkers
        view.isSnappingEnabled = isSnappingEnabled
        view.activeTool = activeTool
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
        view.onReorder = onReorder
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
    var missingAssetIDs: Set<AssetID> = []
    var selection: Set<ItemID> = []
    var playhead = RationalTime.zero
    var duration = RationalTime.zero
    var inPoint: RationalTime?
    var outPoint: RationalTime?
    var clickMarkers: [TimelineClickMarker] = []
    var isSnappingEnabled = true
    var activeTool = TimelineTool.select
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
    var onReorder: ((ItemID, Int) -> Void)?
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
    private var dropIndex: Int?
    private var snapIndicator: RationalTime?
    private var hoveredItemID: ItemID?
    private var hoveredEdge: Edge?
    private var hoveredTime: RationalTime?
    private var trackingArea: NSTrackingArea?
    private var pendingSeek: RationalTime?
    private var seekIsScheduled = false

    private enum Gesture {
        case scrub
        case move(itemID: ItemID, kind: TrackKind, originalIndex: Int)
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
        drawLaneLabels()
        drawVideo()
        drawAudio()
        drawClicks()
        drawCaptions()
        drawProjectMarkers()
        drawInOutPoints()
        drawDropMarker()
        drawSnapGuide()
        drawHoverGuide()
        drawPlayhead()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
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
            } else if hit.trackIndex == 0 {
                gesture = .move(
                    itemID: hit.item.id,
                    kind: hit.kind,
                    originalIndex: hit.index
                )
                dropIndex = hit.index
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
        case .move(_, let kind, _):
            autoscroll(with: event)
            dropIndex = insertionIndex(at: point.x, kind: kind)
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
            dropIndex = nil
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
        case .move(let itemID, _, let originalIndex):
            if let dropIndex, dropIndex != originalIndex {
                onReorder?(itemID, dropIndex)
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

    private func insertionIndex(at x: CGFloat, kind: TrackKind) -> Int {
        let items = (kind == .video ? videoItemRects() : audioItemRects())
            .filter { $0.trackIndex == 0 }
        for item in items where x < item.rect.midX {
            return item.index
        }
        return max(items.count - 1, 0)
    }

    private func time(at x: CGFloat) -> RationalTime {
        let seconds = min(
            max((x - labelWidth) / pointsPerSecond, 0),
            CGFloat(duration.seconds)
        )
        return RationalTime(seconds: seconds)
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
                color: textTertiary
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
                    color: textTertiary
                )
            }
        }
        drawText("●", at: NSPoint(x: 17, y: clickY - 2), color: clickColor)
        drawText("CC", at: NSPoint(x: 13, y: captionY - 2), color: textTertiary)
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
            items = videoItemRects().map { video in
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
        let mediaChildren = (videoItemRects() + audioItemRects()).map {
            media -> NSAccessibilityElement in
            let element = NSAccessibilityElement()
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
        setAccessibilityChildren(mediaChildren + clickChildren)
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

    private func drawDropMarker() {
        guard case .move(_, let kind, let originalIndex) = gesture,
            let dropIndex,
            !(kind == .video ? videoItemRects() : audioItemRects()).isEmpty
        else { return }
        let items = (kind == .video ? videoItemRects() : audioItemRects())
            .filter { $0.trackIndex == 0 }
        let target = items[min(dropIndex, items.count - 1)].rect
        let x = dropIndex > originalIndex ? target.maxX : target.minX
        accent.setFill()
        NSRect(
            x: x - 1,
            y: target.minY - 3,
            width: 2,
            height: target.height + 6
        ).fill()
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
