import Foundation

/// Produces validated, undoable graph patches for timeline gestures.
public enum TimelineEditPlanner {
    public static func splitClip(
        in document: ProjectDocument,
        itemID: ItemID,
        at timelineTime: RationalTime,
        rightItemID: ItemID,
        minimumBoundaryDistance: RationalTime = RationalTime(seconds: 0.4)
    ) throws -> GraphPatch {
        let location = try itemLocation(in: document, itemID: itemID)
        let item = location.track.items[location.index]
        let localTimelineTime = timelineTime - item.timelineStart
        guard localTimelineTime >= minimumBoundaryDistance,
            item.timelineDuration - localTimelineTime >= minimumBoundaryDistance
        else {
            throw ModelError.splitTooCloseToBoundary(
                itemID,
                minimumDistance: minimumBoundaryDistance
            )
        }

        let sourceOffset = localTimelineTime.scaled(by: item.speed)
        let leftRange = TimeRange(
            start: item.sourceRange.start,
            duration: sourceOffset
        )
        let rightRange = TimeRange(
            start: item.sourceRange.start + sourceOffset,
            duration: item.sourceRange.duration - sourceOffset
        )
        let leftWindow = TimeRange(start: .zero, duration: sourceOffset)
        let rightWindow = TimeRange(
            start: sourceOffset,
            duration: item.sourceRange.duration - sourceOffset
        )
        let leftEffects = item.effects.compactMap { sliced($0, to: leftWindow, shiftingBy: .zero) }
        let rightEffects = item.effects.compactMap {
            sliced($0, to: rightWindow, shiftingBy: sourceOffset)
        }

        var leftItem = item
        leftItem.sourceRange = leftRange
        leftItem.effects = leftEffects
        leftItem.videoFade.fadeOut = .zero
        leftItem.audioFade.fadeOut = .zero
        var rightItem = item
        rightItem.id = rightItemID
        rightItem.sourceRange = rightRange
        rightItem.effects = rightEffects
        rightItem.timelineStart = timelineTime
        rightItem.videoFade.fadeIn = .zero
        rightItem.audioFade.fadeIn = .zero

        var items = location.track.items
        items[location.index] = leftItem
        items.insert(rightItem, at: location.index + 1)
        return replacementPatch(trackID: location.track.id, items: items, label: "Split Clip")
    }

    public static func trimClip(
        in document: ProjectDocument,
        itemID: ItemID,
        to requestedRange: TimeRange,
        assetDuration: RationalTime
    ) throws -> GraphPatch {
        let location = try itemLocation(in: document, itemID: itemID)
        let item = location.track.items[location.index]
        guard assetDuration >= .zero else {
            throw ModelError.rangeExceedsAsset(
                itemID,
                requested: requestedRange,
                assetDuration: assetDuration
            )
        }
        let assetRange = TimeRange(start: .zero, duration: assetDuration)
        let range = requestedRange.clamped(to: assetRange)
        var items = location.track.items
        let previousDuration = item.timelineDuration
        items[location.index] = trimming(item, to: range)

        let isPrimaryVideo = document.timeline.videoTracks.first?.id == location.track.id
        let isPrimaryAudio = document.timeline.audioTracks.first?.id == location.track.id
        if isPrimaryVideo || isPrimaryAudio {
            let delta = items[location.index].timelineDuration - previousDuration
            if location.index + 1 < items.count {
                for index in (location.index + 1)..<items.count {
                    items[index].timelineStart = items[index].timelineStart + delta
                }
            }
        }
        return replacementPatch(trackID: location.track.id, items: items, label: "Trim Clip")
    }

    public static func reorderClip(
        _ itemID: ItemID,
        toIndex index: Int
    ) -> GraphPatch {
        GraphPatch(
            ops: [.moveItem(itemID, toIndex: index)],
            label: "Reorder Clips",
            origin: .user
        )
    }

    public static func setSpeed(
        of itemID: ItemID,
        to speed: Double
    ) -> GraphPatch {
        GraphPatch(
            ops: [.setSpeed(itemID, speed)],
            label: "Change Speed",
            origin: .user
        )
    }

    /// Removes an item and closes its occupied interval on the primary video
    /// track. Project markers and captions ripple with the media.
    public static func rippleDelete(
        in document: ProjectDocument,
        itemID: ItemID
    ) throws -> GraphPatch {
        guard let track = document.timeline.videoTracks.first,
            let index = track.items.firstIndex(where: { $0.id == itemID })
        else {
            throw ModelError.itemNotFound(itemID)
        }
        let removed = track.items[index]
        var items = track.items
        items.remove(at: index)
        for following in index..<items.count {
            items[following].timelineStart =
                items[following].timelineStart - removed.timelineDuration
        }

        let deletedRange = TimeRange(
            start: removed.timelineStart,
            duration: removed.timelineDuration
        )
        let markers = document.timeline.markers.map { marker in
            var marker = marker
            if marker.time >= deletedRange.end {
                marker.time = marker.time - deletedRange.duration
            } else if marker.time >= deletedRange.start {
                marker.time = deletedRange.start
            }
            return marker
        }
        let captions = document.timeline.captions.compactMap {
            rippledCaption($0, deleting: deletedRange)
        }
        return GraphPatch(
            ops: [
                .setTrackItems(track.id, items),
                .setMarkers(markers),
                .setCaptions(captions),
            ],
            label: "Ripple Delete",
            origin: .user
        )
    }

    /// Moves the cut between two adjacent items without changing total duration.
    public static func rollEdit(
        in document: ProjectDocument,
        leftItemID: ItemID,
        by delta: RationalTime,
        assetDurations: [AssetID: RationalTime],
        minimumDuration: RationalTime = RationalTime(seconds: 0.1)
    ) throws -> GraphPatch {
        let location = try adjacentLocation(in: document, leftItemID: leftItemID)
        var items = location.track.items
        let left = items[location.index]
        let right = items[location.index + 1]
        guard left.timelineEnd == right.timelineStart else {
            throw ModelError.invalidEdit("Roll requires a gapless cut.")
        }

        let leftTimelineDuration = left.timelineDuration + delta
        let rightTimelineDuration = right.timelineDuration - delta
        guard leftTimelineDuration >= minimumDuration,
            rightTimelineDuration >= minimumDuration
        else {
            throw ModelError.invalidEdit("Roll would make a clip too short.")
        }
        let leftRange = TimeRange(
            start: left.sourceRange.start,
            duration: leftTimelineDuration.scaled(by: left.speed)
        )
        let rightSourceDelta = delta.scaled(by: right.speed)
        let rightRange = TimeRange(
            start: right.sourceRange.start + rightSourceDelta,
            duration: rightTimelineDuration.scaled(by: right.speed)
        )
        try validateSourceRange(leftRange, for: left, assetDurations: assetDurations)
        try validateSourceRange(rightRange, for: right, assetDurations: assetDurations)

        items[location.index] = trimming(left, to: leftRange)
        var adjustedRight = trimming(right, to: rightRange)
        adjustedRight.timelineStart = left.timelineStart + leftTimelineDuration
        items[location.index + 1] = adjustedRight
        return replacementPatch(trackID: location.track.id, items: items, label: "Roll Edit")
    }

    /// Changes the selected source window without moving the item in project time.
    public static func slipClip(
        in document: ProjectDocument,
        itemID: ItemID,
        by sourceDelta: RationalTime,
        assetDuration: RationalTime
    ) throws -> GraphPatch {
        let location = try itemLocation(in: document, itemID: itemID)
        var items = location.track.items
        var item = items[location.index]
        let range = TimeRange(
            start: item.sourceRange.start + sourceDelta,
            duration: item.sourceRange.duration
        )
        try validateSourceRange(range, for: item, assetDurations: [item.assetID: assetDuration])
        item.sourceRange = range
        items[location.index] = item
        return replacementPatch(trackID: location.track.id, items: items, label: "Slip Clip")
    }

    /// Moves an item between its two neighbours while preserving both the
    /// selected source window and the total track duration.
    public static func slideClip(
        in document: ProjectDocument,
        itemID: ItemID,
        by delta: RationalTime,
        assetDurations: [AssetID: RationalTime],
        minimumDuration: RationalTime = RationalTime(seconds: 0.1)
    ) throws -> GraphPatch {
        let location = try itemLocation(in: document, itemID: itemID)
        guard location.index > 0, location.index + 1 < location.track.items.count else {
            throw ModelError.invalidEdit("Slide requires clips on both sides.")
        }
        var items = location.track.items
        let left = items[location.index - 1]
        var selected = items[location.index]
        let right = items[location.index + 1]
        guard left.timelineEnd == selected.timelineStart,
            selected.timelineEnd == right.timelineStart
        else {
            throw ModelError.invalidEdit("Slide requires gapless neighbours.")
        }

        let leftDuration = left.timelineDuration + delta
        let rightDuration = right.timelineDuration - delta
        guard leftDuration >= minimumDuration, rightDuration >= minimumDuration else {
            throw ModelError.invalidEdit("Slide would make a neighbouring clip too short.")
        }
        let leftRange = TimeRange(
            start: left.sourceRange.start,
            duration: leftDuration.scaled(by: left.speed)
        )
        let rightDelta = delta.scaled(by: right.speed)
        let rightRange = TimeRange(
            start: right.sourceRange.start + rightDelta,
            duration: rightDuration.scaled(by: right.speed)
        )
        try validateSourceRange(leftRange, for: left, assetDurations: assetDurations)
        try validateSourceRange(rightRange, for: right, assetDurations: assetDurations)

        items[location.index - 1] = trimming(left, to: leftRange)
        selected.timelineStart = selected.timelineStart + delta
        items[location.index] = selected
        var adjustedRight = trimming(right, to: rightRange)
        adjustedRight.timelineStart = selected.timelineEnd
        items[location.index + 1] = adjustedRight
        return replacementPatch(trackID: location.track.id, items: items, label: "Slide Clip")
    }

    /// Inserts an item at an existing edge or gap and ripples subsequent items.
    public static func rippleInsert(
        in document: ProjectDocument,
        item: TimelineItem,
        on trackID: TrackID,
        at time: RationalTime
    ) throws -> GraphPatch {
        let track = try track(in: document, id: trackID)
        guard !track.items.contains(where: { time > $0.timelineStart && time < $0.timelineEnd })
        else {
            throw ModelError.invalidEdit("Ripple insert must begin at a clip edge or gap.")
        }
        var inserted = item
        inserted.timelineStart = time
        var items = track.items.map { existing in
            var existing = existing
            if existing.timelineStart >= time {
                existing.timelineStart = existing.timelineStart + inserted.timelineDuration
            }
            return existing
        }
        items.append(inserted)
        items.sort { $0.timelineStart < $1.timelineStart }
        return replacementPatch(trackID: track.id, items: items, label: "Insert Edit")
    }

    /// Replaces the occupied project interval, trimming or splitting clips that
    /// cross its boundaries.
    public static func overwrite(
        in document: ProjectDocument,
        item: TimelineItem,
        on trackID: TrackID,
        at time: RationalTime,
        splitRightItemID: ItemID
    ) throws -> GraphPatch {
        let track = try track(in: document, id: trackID)
        var inserted = item
        inserted.timelineStart = time
        let window = TimeRange(start: time, duration: inserted.timelineDuration)
        var items: [TimelineItem] = []
        for existing in track.items {
            let existingWindow = TimeRange(
                start: existing.timelineStart,
                duration: existing.timelineDuration
            )
            guard existingWindow.intersects(window) else {
                items.append(existing)
                continue
            }
            let retainsLeft = existingWindow.start < window.start
            if retainsLeft {
                let retainedTimeline = window.start - existingWindow.start
                let range = TimeRange(
                    start: existing.sourceRange.start,
                    duration: retainedTimeline.scaled(by: existing.speed)
                )
                items.append(trimming(existing, to: range))
            }
            if existingWindow.end > window.end {
                let removedTimeline = window.end - existingWindow.start
                let sourceOffset = removedTimeline.scaled(by: existing.speed)
                let range = TimeRange(
                    start: existing.sourceRange.start + sourceOffset,
                    duration: (existingWindow.end - window.end).scaled(by: existing.speed)
                )
                var right = trimming(existing, to: range)
                if retainsLeft { right.id = splitRightItemID }
                right.timelineStart = window.end
                items.append(right)
            }
        }
        items.append(inserted)
        items.sort { $0.timelineStart < $1.timelineStart }
        return replacementPatch(trackID: track.id, items: items, label: "Overwrite Edit")
    }

    public static func pasteAttributes(
        from sourceID: ItemID,
        to destinationIDs: [ItemID],
        in document: ProjectDocument
    ) throws -> GraphPatch {
        guard let source = document.item(sourceID) else { throw ModelError.itemNotFound(sourceID) }
        var operations: [GraphOp] = []
        for track in document.timeline.videoTracks + document.timeline.audioTracks {
            var items = track.items
            var changed = false
            for index in items.indices where destinationIDs.contains(items[index].id) {
                items[index].effects = source.effects.filter {
                    $0.range.end <= items[index].sourceRange.duration
                }
                items[index].transform = source.transform
                items[index].opacity = source.opacity
                items[index].blendMode = source.blendMode
                items[index].videoFade = source.videoFade
                items[index].audioFade = source.audioFade
                changed = true
            }
            if changed { operations.append(.setTrackItems(track.id, items)) }
        }
        return GraphPatch(ops: operations, label: "Paste Attributes", origin: .user)
    }

    public static func addMarker(
        to document: ProjectDocument,
        marker: Marker
    ) -> GraphPatch {
        var markers = document.timeline.markers.filter { $0.id != marker.id }
        markers.append(marker)
        markers.sort { $0.time < $1.time }
        return GraphPatch(ops: [.setMarkers(markers)], label: "Add Marker", origin: .user)
    }

    public static func removeMarker(
        from document: ProjectDocument,
        id: MarkerID
    ) -> GraphPatch {
        GraphPatch(
            ops: [.setMarkers(document.timeline.markers.filter { $0.id != id })],
            label: "Remove Marker",
            origin: .user
        )
    }

    /// Applies matching visual fade handles to both sides of a cut.
    public static func crossDissolve(
        in document: ProjectDocument,
        leftItemID: ItemID,
        duration: RationalTime
    ) throws -> GraphPatch {
        let location = try adjacentLocation(in: document, leftItemID: leftItemID)
        guard duration > .zero else {
            throw ModelError.invalidEdit("A transition needs a positive duration.")
        }
        var items = location.track.items
        guard duration <= items[location.index].timelineDuration,
            duration <= items[location.index + 1].timelineDuration
        else {
            throw ModelError.invalidEdit("The transition is longer than a neighbouring clip.")
        }
        items[location.index].videoFade.fadeOut = duration
        items[location.index + 1].videoFade.fadeIn = duration
        return replacementPatch(
            trackID: location.track.id,
            items: items,
            label: "Cross Dissolve"
        )
    }

    public static func setAudioFade(
        in document: ProjectDocument,
        itemID: ItemID,
        fadeIn: RationalTime,
        fadeOut: RationalTime
    ) throws -> GraphPatch {
        let location = try itemLocation(in: document, itemID: itemID)
        guard fadeIn >= .zero, fadeOut >= .zero,
            fadeIn <= location.track.items[location.index].timelineDuration,
            fadeOut <= location.track.items[location.index].timelineDuration
        else {
            throw ModelError.invalidFade(itemID)
        }
        var items = location.track.items
        items[location.index].audioFade = FadeEnvelope(fadeIn: fadeIn, fadeOut: fadeOut)
        return replacementPatch(trackID: location.track.id, items: items, label: "Audio Fade")
    }

    public static func setOpacityKeyframe(
        in document: ProjectDocument,
        itemID: ItemID,
        at localTime: RationalTime,
        value: Double,
        easing: Easing = .smoothstep
    ) throws -> GraphPatch {
        guard (0...1).contains(value) else { throw ModelError.invalidOpacity(itemID, value) }
        let location = try itemLocation(in: document, itemID: itemID)
        var items = location.track.items
        items[location.index].opacity.setKeyframe(
            Keyframe(time: localTime, value: value, easing: easing)
        )
        return replacementPatch(trackID: location.track.id, items: items, label: "Opacity Keyframe")
    }

    public static func setTransformKeyframe(
        in document: ProjectDocument,
        itemID: ItemID,
        at localTime: RationalTime,
        value: Transform2D,
        easing: Easing = .smoothstep
    ) throws -> GraphPatch {
        let location = try itemLocation(in: document, itemID: itemID)
        var items = location.track.items
        items[location.index].transform.setKeyframe(
            Keyframe(time: localTime, value: value, easing: easing)
        )
        return replacementPatch(
            trackID: location.track.id,
            items: items,
            label: "Transform Keyframe"
        )
    }

    public static func setGainKeyframe(
        in document: ProjectDocument,
        trackID: TrackID,
        at projectTime: RationalTime,
        decibels: Double,
        easing: Easing = .smoothstep
    ) throws -> GraphPatch {
        guard decibels.isFinite else { throw ModelError.invalidTrackGain(trackID, decibels) }
        var track = try track(in: document, id: trackID)
        track.gain.setKeyframe(
            Keyframe(time: projectTime, value: decibels, easing: easing)
        )
        return GraphPatch(ops: [.setTrack(track)], label: "Gain Keyframe", origin: .user)
    }

    public static func setBlurIntensityKeyframe(
        in document: ProjectDocument,
        itemID: ItemID,
        effectID: EffectID,
        at localTime: RationalTime,
        value: Double,
        easing: Easing = .smoothstep
    ) throws -> GraphPatch {
        let location = try itemLocation(in: document, itemID: itemID)
        var items = location.track.items
        guard
            let effectIndex = items[location.index].effects.firstIndex(where: {
                $0.id == effectID
            }), case .blur(var blur) = items[location.index].effects[effectIndex]
        else {
            throw ModelError.effectNotFound(itemID, effectID)
        }
        var animation = blur.intensityAnimation ?? Animatable(constant: blur.mode.constantIntensity)
        animation.setKeyframe(Keyframe(time: localTime, value: value, easing: easing))
        blur.intensityAnimation = animation
        items[location.index].effects[effectIndex] = .blur(blur)
        return replacementPatch(
            trackID: location.track.id,
            items: items,
            label: "Blur Keyframe"
        )
    }

    public static func setZoomScaleKeyframe(
        in document: ProjectDocument,
        itemID: ItemID,
        effectID: EffectID,
        at localTime: RationalTime,
        value: Double,
        easing: Easing = .smoothstep
    ) throws -> GraphPatch {
        let location = try itemLocation(in: document, itemID: itemID)
        var items = location.track.items
        guard
            let effectIndex = items[location.index].effects.firstIndex(where: {
                $0.id == effectID
            }), case .zoom(var zoom) = items[location.index].effects[effectIndex]
        else {
            throw ModelError.effectNotFound(itemID, effectID)
        }
        zoom.scaleAnimation.setKeyframe(
            Keyframe(time: localTime, value: value, easing: easing)
        )
        zoom.preservesLegacyTiming = false
        items[location.index].effects[effectIndex] = .zoom(zoom)
        return replacementPatch(
            trackID: location.track.id,
            items: items,
            label: "Zoom Keyframe"
        )
    }
}

extension TimelineEditPlanner {
    fileprivate static func replacementPatch(
        trackID: TrackID,
        items: [TimelineItem],
        label: String
    ) -> GraphPatch {
        GraphPatch(ops: [.setTrackItems(trackID, items)], label: label, origin: .user)
    }

    fileprivate static func itemLocation(
        in document: ProjectDocument,
        itemID: ItemID
    ) throws -> (track: Track, index: Int) {
        for track in document.timeline.videoTracks + document.timeline.audioTracks {
            if let index = track.items.firstIndex(where: { $0.id == itemID }) {
                return (track, index)
            }
        }
        throw ModelError.itemNotFound(itemID)
    }

    fileprivate static func adjacentLocation(
        in document: ProjectDocument,
        leftItemID: ItemID
    ) throws -> (track: Track, index: Int) {
        let location = try itemLocation(in: document, itemID: leftItemID)
        guard location.index + 1 < location.track.items.count else {
            throw ModelError.invalidEdit("Roll requires a clip on the right.")
        }
        return location
    }

    fileprivate static func track(in document: ProjectDocument, id: TrackID) throws -> Track {
        if let track = document.timeline.videoTracks.first(where: { $0.id == id }) {
            return track
        }
        if let track = document.timeline.audioTracks.first(where: { $0.id == id }) {
            return track
        }
        throw ModelError.trackNotFound(id)
    }

    fileprivate static func validateSourceRange(
        _ range: TimeRange,
        for item: TimelineItem,
        assetDurations: [AssetID: RationalTime]
    ) throws {
        guard range.start >= .zero, range.duration >= .zero,
            let duration = assetDurations[item.assetID],
            range.end <= duration
        else {
            throw ModelError.rangeExceedsAsset(
                item.id,
                requested: range,
                assetDuration: assetDurations[item.assetID] ?? item.sourceRange.end
            )
        }
    }

    fileprivate static func trimming(_ item: TimelineItem, to range: TimeRange) -> TimelineItem {
        var item = item
        let retained = TimeRange(
            start: range.start - item.sourceRange.start,
            duration: range.duration
        )
        item.effects = item.effects.compactMap {
            sliced($0, to: retained, shiftingBy: retained.start)
        }
        item.sourceRange = range
        item.videoFade.fadeIn = min(item.videoFade.fadeIn, item.timelineDuration)
        item.videoFade.fadeOut = min(item.videoFade.fadeOut, item.timelineDuration)
        item.audioFade.fadeIn = min(item.audioFade.fadeIn, item.timelineDuration)
        item.audioFade.fadeOut = min(item.audioFade.fadeOut, item.timelineDuration)
        return item
    }

    fileprivate static func rippledCaption(
        _ caption: CaptionSegment,
        deleting deleted: TimeRange
    ) -> CaptionSegment? {
        if caption.range.end <= deleted.start { return caption }
        if caption.range.start >= deleted.end {
            var shifted = caption
            shifted.range.start = shifted.range.start - deleted.duration
            return shifted
        }
        let overlap = caption.range.clamped(to: deleted).duration
        guard overlap < caption.range.duration else { return nil }
        var shortened = caption
        shortened.range.start = min(caption.range.start, deleted.start)
        shortened.range.duration = caption.range.duration - overlap
        return shortened
    }

    fileprivate static func removeAllEffects(from item: TimelineItem) -> [GraphOp] {
        item.effects.reversed().map { .removeEffect(item.id, $0.id) }
    }

    fileprivate static func sliced(
        _ effect: Effect,
        to window: TimeRange,
        shiftingBy offset: RationalTime
    ) -> Effect? {
        let intersection = effect.range.clamped(to: window)
        guard intersection.duration > .zero else { return nil }
        return effect.replacingRange(
            TimeRange(
                start: intersection.start - offset,
                duration: intersection.duration
            )
        )
    }
}
