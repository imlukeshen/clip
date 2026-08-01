import Foundation

extension ProjectDocument {
    /// Returns an item from either media track.
    public func item(_ id: ItemID) -> TimelineItem? {
        timeline.video.first(where: { $0.id == id })
            ?? timeline.audio.first(where: { $0.id == id })
    }

    /// Returns the derived gapless start of an item in its owning track.
    public func timelineStart(of id: ItemID) -> RationalTime? {
        for track in [timeline.video, timeline.audio] {
            var start = RationalTime.zero
            for item in track {
                if item.id == id {
                    return start
                }
                start = start + item.timelineDuration
            }
        }
        return nil
    }

    /// Returns the video item and item-local timeline time at a project timestamp.
    public func item(at time: RationalTime) -> (item: TimelineItem, local: RationalTime)? {
        guard time >= .zero else { return nil }
        var start = RationalTime.zero
        for item in timeline.video {
            let end = start + item.timelineDuration
            if time >= start && time < end {
                return (item, time - start)
            }
            start = end
        }
        return nil
    }

    /// The gapless video-track duration.
    public var duration: RationalTime {
        timeline.video.reduce(.zero) { $0 + $1.timelineDuration }
    }

    /// Verifies schema, geometry, identity, timing, and clip-local effect invariants.
    public func validate() throws {
        guard schemaVersion <= ProjectDocument.currentSchemaVersion else {
            throw ModelError.schemaTooNew(
                found: schemaVersion,
                supported: ProjectDocument.currentSchemaVersion
            )
        }
        guard canvas.width > 0,
            canvas.height > 0,
            canvas.width.isMultiple(of: 2),
            canvas.height.isMultiple(of: 2)
        else {
            throw ModelError.invalidCanvas(width: canvas.width, height: canvas.height)
        }

        var itemIDs = Set<ItemID>()
        for item in timeline.video + timeline.audio {
            guard itemIDs.insert(item.id).inserted else {
                throw ModelError.duplicateItem(item.id)
            }
            try validate(item)
        }

        for caption in timeline.captions {
            guard caption.range.start >= .zero, caption.range.duration >= .zero else {
                throw ModelError.invalidRange(caption.range)
            }
        }
    }

    private func validate(_ item: TimelineItem) throws {
        guard item.speed.isFinite, (0.25...4).contains(item.speed) else {
            throw ModelError.invalidSpeed(item.speed)
        }
        guard item.sourceRange.start >= .zero, item.sourceRange.duration >= .zero else {
            throw ModelError.invalidRange(item.sourceRange)
        }

        var effectIDs = Set<EffectID>()
        let clipRange = TimeRange(start: .zero, duration: item.sourceRange.duration)
        for effect in item.effects {
            guard effectIDs.insert(effect.id).inserted else {
                throw ModelError.duplicateEffect(item.id, effect.id)
            }
            guard effect.range.start >= clipRange.start,
                effect.range.duration >= .zero,
                effect.range.end <= clipRange.end
            else {
                throw ModelError.effectRangeExceedsItem(item.id, effect.id)
            }
        }
    }
}
