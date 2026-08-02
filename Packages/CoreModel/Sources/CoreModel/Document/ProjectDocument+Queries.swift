import Foundation

extension ProjectDocument {
    /// Returns an item from either media track.
    public func item(_ id: ItemID) -> TimelineItem? {
        timeline.videoTracks.lazy.flatMap(\.items).first(where: { $0.id == id })
            ?? timeline.audioTracks.lazy.flatMap(\.items).first(where: { $0.id == id })
    }

    /// Returns the explicit project start of an item in its owning track.
    public func timelineStart(of id: ItemID) -> RationalTime? {
        item(id)?.timelineStart
    }

    /// Returns the video item and item-local timeline time at a project timestamp.
    public func item(at time: RationalTime) -> (item: TimelineItem, local: RationalTime)? {
        guard time >= .zero else { return nil }
        for track in timeline.videoTracks.reversed() where track.isEnabled {
            for item in track.items.reversed() where item.isEnabled {
                if time >= item.timelineStart && time < item.timelineEnd {
                    return (item, time - item.timelineStart)
                }
            }
        }
        return nil
    }

    /// The end of the final video item across all video tracks. Disabled media
    /// still occupies timeline time and renders as a gap.
    public var duration: RationalTime {
        timeline.videoTracks
            .flatMap(\.items)
            .map(\.timelineEnd)
            .max() ?? .zero
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

        var trackIDs = Set<TrackID>()
        var itemIDs = Set<ItemID>()
        for track in timeline.videoTracks + timeline.audioTracks {
            guard trackIDs.insert(track.id).inserted else {
                throw ModelError.duplicateTrack(track.id)
            }
            guard track.gain.isFinite else {
                throw ModelError.invalidTrackGain(track.id, track.gain)
            }
            var previousEnd: RationalTime?
            for item in track.items {
                guard itemIDs.insert(item.id).inserted else {
                    throw ModelError.duplicateItem(item.id)
                }
                guard previousEnd.map({ item.timelineStart >= $0 }) ?? true else {
                    throw ModelError.overlappingItems(track.id)
                }
                try validate(item)
                previousEnd = item.timelineEnd
            }
        }

        for caption in timeline.captions {
            guard caption.range.start >= .zero, caption.range.duration >= .zero else {
                throw ModelError.invalidRange(caption.range)
            }
        }
        for marker in timeline.markers where marker.time < .zero {
            throw ModelError.invalidMarkerTime(marker.id, marker.time)
        }
    }

    private func validate(_ item: TimelineItem) throws {
        guard item.speed.isFinite, (0.25...4).contains(item.speed) else {
            throw ModelError.invalidSpeed(item.speed)
        }
        guard item.sourceRange.start >= .zero, item.sourceRange.duration >= .zero else {
            throw ModelError.invalidRange(item.sourceRange)
        }
        guard item.timelineStart >= .zero else {
            throw ModelError.invalidTimelineStart(item.id, item.timelineStart)
        }
        guard item.opacity.isFinite, (0...1).contains(item.opacity) else {
            throw ModelError.invalidOpacity(item.id, item.opacity)
        }
        let transform = item.transform
        guard transform.translationX.isFinite,
            transform.translationY.isFinite,
            transform.scaleX.isFinite,
            transform.scaleY.isFinite,
            transform.rotationDegrees.isFinite,
            transform.scaleX != 0,
            transform.scaleY != 0
        else {
            throw ModelError.invalidTransform(item.id)
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
