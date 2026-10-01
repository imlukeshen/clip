import Foundation

extension TimelineItem {
    /// This item with `old`'s transform and opacity keyframes moved onto its
    /// own timeline, and its fades clamped to its length.
    ///
    /// Keyframes are stored in item-local timeline time, so any edit that
    /// changes where the item starts in its source, or how fast it plays,
    /// must re-time them: otherwise an animation drifts against the picture
    /// after a head trim, and a keyframe past a shortened end makes the
    /// document invalid (a split or trim simply fails).
    func retimingAnimations(from old: TimelineItem) -> TimelineItem {
        var item = self
        let oldStart = old.sourceRange.start
        let oldSpeed = old.speed
        let newStart = item.sourceRange.start
        let newSpeed = item.speed
        let duration = item.timelineDuration
        let map: (RationalTime) -> RationalTime = { time in
            (oldStart + time.scaled(by: oldSpeed) - newStart).scaled(by: 1 / newSpeed)
        }
        let unmap: (RationalTime) -> RationalTime = { time in
            (newStart + time.scaled(by: newSpeed) - oldStart).scaled(by: 1 / oldSpeed)
        }
        item.transform = old.transform.retimed(duration: duration, map: map, unmap: unmap)
        item.opacity = old.opacity.retimed(duration: duration, map: map, unmap: unmap)
        item.videoFade.fadeIn = min(item.videoFade.fadeIn, duration)
        item.videoFade.fadeOut = min(item.videoFade.fadeOut, duration)
        item.audioFade.fadeIn = min(item.audioFade.fadeIn, duration)
        item.audioFade.fadeOut = min(item.audioFade.fadeOut, duration)
        return item
    }
}

extension Effect {
    /// The effect's own keyframes and timed regions moved `offset` earlier,
    /// matching a range that was rebased by the same amount, and limited to
    /// the clip's new source length.
    func shiftingAnimations(by offset: RationalTime, within duration: RationalTime) -> Effect {
        switch self {
        case .zoom(var zoom):
            zoom.scaleAnimation = zoom.scaleAnimation.shifted(by: offset, within: duration)
            zoom.centerAnimation = zoom.centerAnimation.shifted(by: offset, within: duration)
            return .zoom(zoom)
        case .blur(var blur):
            blur.intensityAnimation = blur.intensityAnimation?.shifted(by: offset, within: duration)
            // Regions step rather than interpolate: keep the one in force at the
            // new start, then those inside the window.
            let moved = blur.regions.map { region -> TimedRegion in
                var region = region
                region.time = region.time - offset
                return region
            }
            var kept = moved.filter { $0.time >= .zero && $0.time <= duration }
            if let inForce = moved.last(where: { $0.time < .zero }),
                kept.first?.time != .zero
            {
                var start = inForce
                start.time = .zero
                kept.insert(start, at: 0)
            }
            if kept.isEmpty, var first = moved.first {
                first.time = .zero
                kept = [first]
            }
            blur.regions = kept
            return .blur(blur)
        case .crop, .background, .cursor, .text, .unknown:
            return self
        }
    }
}
