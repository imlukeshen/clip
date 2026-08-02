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
    let clickMarkers: [TimelineClickMarker]
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
    let onSelect: (ItemID, Bool) -> Void
    let onSeek: (RationalTime, Bool) -> Void
    let onScrubbing: (Bool) -> Void
    let onReorder: (ItemID, Int) -> Void
    let onTrim: (ItemID, TimeRange) -> Void

    func makeNSView(context: Context) -> TimelineCanvas {
        TimelineCanvas()
    }

    func updateNSView(_ view: TimelineCanvas, context: Context) {
        view.timeline = timeline
        view.names = names
        view.assetDurations = assetDurations
        view.missingAssetIDs = missingAssetIDs
        view.selection = selection
        view.playhead = playhead
        view.duration = duration
        view.clickMarkers = clickMarkers
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
        view.onSelect = onSelect
        view.onSeek = onSeek
        view.onScrubbing = onScrubbing
        view.onReorder = onReorder
        view.onTrim = onTrim
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
    var clickMarkers: [TimelineClickMarker] = []
    var accent = NSColor.systemBlue
    var accentDim = NSColor.systemBlue.withAlphaComponent(0.2)
    var surface = NSColor.black
    var clipColor = NSColor.darkGray
    var lineColor = NSColor.gray
    var textPrimary = NSColor.white
    var textTertiary = NSColor.lightGray
    var audioColor = NSColor.green
    var clickColor = NSColor.orange
    var captionColor = NSColor.blue
    var playheadColor = NSColor.red
    var onSelect: ((ItemID, Bool) -> Void)?
    var onSeek: ((RationalTime, Bool) -> Void)?
    var onScrubbing: ((Bool) -> Void)?
    var onReorder: ((ItemID, Int) -> Void)?
    var onTrim: ((ItemID, TimeRange) -> Void)?

    private let labelWidth: CGFloat = 46
    private let rulerHeight: CGFloat = 24
    private let videoHeight: CGFloat = 34
    private let audioHeight: CGFloat = 16
    private let eventHeight: CGFloat = 11
    private let laneGap: CGFloat = 6
    private var gesture: Gesture?
    private var previewRange: (ItemID, TimeRange)?
    private var dropIndex: Int?

    private enum Gesture {
        case scrub
        case move(itemID: ItemID, originalIndex: Int)
        case trim(
            itemID: ItemID,
            edge: Edge,
            original: TimeRange,
            speed: Double,
            originX: CGFloat
        )
    }

    private enum Edge { case leading, trailing }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

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
        drawDropMarker()
        drawPlayhead()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = clip(at: point) {
            onSelect?(hit.item.id, event.modifierFlags.contains(.shift))
            onSeek?(time(at: point.x), true)
            if abs(point.x - hit.rect.minX) <= 7 {
                gesture = .trim(
                    itemID: hit.item.id,
                    edge: .leading,
                    original: hit.item.sourceRange,
                    speed: hit.item.speed,
                    originX: point.x
                )
            } else if abs(point.x - hit.rect.maxX) <= 7 {
                gesture = .trim(
                    itemID: hit.item.id,
                    edge: .trailing,
                    original: hit.item.sourceRange,
                    speed: hit.item.speed,
                    originX: point.x
                )
            } else {
                gesture = .move(itemID: hit.item.id, originalIndex: hit.index)
                dropIndex = hit.index
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
        switch gesture {
        case .scrub:
            onSeek?(time(at: point.x), false)
        case .move:
            dropIndex = insertionIndex(at: point.x)
            needsDisplay = true
        case .trim(let itemID, let edge, let original, let speed, let originX):
            let sourceDelta = RationalTime(
                seconds: (point.x - originX) / pointsPerSecond * speed
            )
            let minimum = RationalTime(seconds: 0.1)
            guard let item = timeline.video.first(where: { $0.id == itemID }),
                let assetDuration = assetDurations[item.assetID]
            else { return }
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
            needsDisplay = true
        }
        guard let gesture else { return }
        switch gesture {
        case .scrub:
            let point = convert(event.locationInWindow, from: nil)
            onSeek?(time(at: point.x), true)
            onScrubbing?(false)
        case .move(let itemID, let originalIndex):
            if let dropIndex, dropIndex != originalIndex {
                onReorder?(itemID, dropIndex)
            }
        case .trim(let itemID, _, let original, _, _):
            if let previewRange, previewRange.1 != original {
                onTrim?(itemID, previewRange.1)
            }
        }
    }

    private var pointsPerSecond: CGFloat {
        max((bounds.width - labelWidth) / max(CGFloat(duration.seconds), 0.01), 1)
    }

    private var videoY: CGFloat { rulerHeight + 4 }
    private var audioY: CGFloat { videoY + videoHeight + laneGap }
    private var clickY: CGFloat { audioY + audioHeight + laneGap }
    private var captionY: CGFloat { clickY + eventHeight + laneGap }

    private func displayItems() -> [TimelineItem] {
        timeline.video.map { item in
            guard let previewRange, previewRange.0 == item.id else { return item }
            var copy = item
            copy.sourceRange = previewRange.1
            return copy
        }
    }

    private func clipRects() -> [(item: TimelineItem, index: Int, rect: NSRect)] {
        var x = labelWidth
        return displayItems().enumerated().map { index, item in
            let width = max(CGFloat(item.timelineDuration.seconds) * pointsPerSecond, 2)
            defer { x += width }
            return (item, index, NSRect(x: x, y: videoY, width: width, height: videoHeight))
        }
    }

    private func clip(at point: NSPoint) -> (item: TimelineItem, index: Int, rect: NSRect)? {
        clipRects().first { $0.rect.insetBy(dx: 0, dy: -2).contains(point) }
    }

    private func insertionIndex(at x: CGFloat) -> Int {
        for clip in clipRects() where x < clip.rect.midX {
            return clip.index
        }
        return max(timeline.video.count - 1, 0)
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
        drawText("V", at: NSPoint(x: 18, y: videoY + 9), color: textTertiary)
        drawText("A", at: NSPoint(x: 18, y: audioY + 1), color: textTertiary)
        drawText("●", at: NSPoint(x: 17, y: clickY - 2), color: clickColor)
        drawText("CC", at: NSPoint(x: 13, y: captionY - 2), color: textTertiary)
    }

    private func drawVideo() {
        for clip in clipRects() {
            let selected = selection.contains(clip.item.id)
            let path = NSBezierPath(
                roundedRect: clip.rect.insetBy(dx: 1, dy: 0), xRadius: 3, yRadius: 3)
            (selected ? accentDim : clipColor).setFill()
            path.fill()
            (selected ? accent : lineColor).setStroke()
            path.lineWidth = selected ? 1.5 : 0.5
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
        for clip in clipRects() {
            let rect = NSRect(
                x: clip.rect.minX + 1,
                y: audioY,
                width: max(clip.rect.width - 2, 1),
                height: audioHeight
            )
            audioColor.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
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
        }
    }

    private func drawClicks() {
        clickColor.setFill()
        for marker in clickMarkers {
            let x = labelWidth + CGFloat(marker.timelineTime.seconds) * pointsPerSecond
            NSRect(x: x - 1, y: clickY, width: 2, height: eventHeight).fill()
        }
        refreshClickAccessibility()
    }

    private func refreshClickAccessibility() {
        let children = clickMarkers.map { marker -> NSAccessibilityElement in
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel("Recorded click")
            element.setAccessibilityValue(formatClickTime(marker.timelineTime.seconds))
            element.setAccessibilityIdentifier(marker.id)
            return element
        }
        setAccessibilityChildren(children)
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

    private func drawDropMarker() {
        guard case .move(_, let originalIndex) = gesture,
            let dropIndex,
            !clipRects().isEmpty
        else { return }
        let clips = clipRects()
        let target = clips[min(dropIndex, clips.count - 1)].rect
        let x = dropIndex > originalIndex ? target.maxX : target.minX
        accent.setFill()
        NSRect(x: x - 1, y: videoY - 3, width: 2, height: videoHeight + 6).fill()
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
}
