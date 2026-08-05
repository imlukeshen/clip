import Foundation

private struct ItemLocation {
    let kind: TrackKind
    let trackIndex: Int
    let itemIndex: Int
    let trackID: TrackID
}

private func assignGaplessTimelineStarts(to items: inout [TimelineItem]) {
    var cursor = RationalTime.zero
    for index in items.indices {
        items[index].timelineStart = cursor
        cursor = cursor + items[index].timelineDuration
    }
}

extension ProjectDocument {
    /// Applies a patch transactionally and returns its exact inverse.
    ///
    /// Operations run against a copy. Any invalid operation leaves the receiver unchanged.
    @discardableResult
    public mutating func apply(_ patch: GraphPatch) throws -> GraphPatch {
        var candidate = self
        try candidate.validate()
        var inverseOperations: [GraphOp] = []
        inverseOperations.reserveCapacity(patch.ops.count)

        for operation in patch.ops {
            let inverse = try candidate.apply(operation)
            inverseOperations.append(inverse)
            try candidate.validate()
        }

        self = candidate
        return GraphPatch(
            ops: inverseOperations.reversed(),
            label: patch.label,
            origin: patch.origin
        )
    }

    private mutating func apply(_ operation: GraphOp) throws -> GraphOp {
        switch operation {
        case .insertItem(let item, let track, let index):
            try ensureUnlocked(track)
            guard self.item(item.id) == nil else {
                throw ModelError.duplicateItem(item.id)
            }
            let previous = items(for: track)
            let count = previous.count
            guard (0...count).contains(index) else {
                throw ModelError.indexOutOfRange(index, count: count)
            }
            let previousTrackID: TrackID?
            let previousTracks: [Track]
            switch track {
            case .video:
                previousTrackID = timeline.videoTracks.first?.id
                previousTracks = timeline.videoTracks
            case .audio:
                previousTrackID = timeline.audioTracks.first?.id
                previousTracks = timeline.audioTracks
            }
            var inserted = item
            inserted.timelineStart =
                index < previous.count
                ? previous[index].timelineStart
                : previous.last?.timelineEnd ?? .zero
            mutateItems(for: track) { items in
                items.insert(inserted, at: index)
                if index + 1 < items.count {
                    for followingIndex in (index + 1)..<items.count {
                        items[followingIndex].timelineStart =
                            items[followingIndex].timelineStart + inserted.timelineDuration
                    }
                }
            }
            if let previousTrackID {
                return .setTrackItems(previousTrackID, previous)
            }
            switch track {
            case .video:
                return .setVideoTracks(previousTracks)
            case .audio:
                return .setAudioTracks(previousTracks)
            }

        case .removeItem(let id):
            let location = try itemLocation(id)
            try ensureUnlocked(location)
            let previous = items(at: location)
            let removed = previous[location.itemIndex]
            let removesLegacyPrimaryTrack =
                location.trackIndex == 0
                && previous.count == 1
                && location.trackID
                    == TrackID(rawValue: location.kind == .video ? "v1" : "a1")
            let previousTracks: [Track]
            switch location.kind {
            case .video:
                previousTracks = timeline.videoTracks
            case .audio:
                previousTracks = timeline.audioTracks
            }
            mutateItems(at: location) { items in
                items.remove(at: location.itemIndex)
                if location.trackIndex == 0, location.itemIndex < items.count {
                    for followingIndex in location.itemIndex..<items.count {
                        items[followingIndex].timelineStart =
                            items[followingIndex].timelineStart - removed.timelineDuration
                    }
                }
            }
            if removesLegacyPrimaryTrack {
                switch location.kind {
                case .video:
                    timeline.videoTracks.removeFirst()
                    return .setVideoTracks(previousTracks)
                case .audio:
                    timeline.audioTracks.removeFirst()
                    return .setAudioTracks(previousTracks)
                }
            }
            return .setTrackItems(location.trackID, previous)

        case .moveItem(let id, let destination):
            let location = try itemLocation(id)
            try ensureUnlocked(location)
            let previous = items(at: location)
            let count = previous.count
            guard (0..<count).contains(destination) else {
                throw ModelError.indexOutOfRange(destination, count: count)
            }
            mutateItems(at: location) { items in
                let moved = items.remove(at: location.itemIndex)
                items.insert(moved, at: destination)
                assignGaplessTimelineStarts(to: &items)
            }
            return .setTrackItems(location.trackID, previous)

        case .setSourceRange(let id, let range):
            let location = try itemLocation(id)
            try ensureUnlocked(location)
            let previous = items(at: location)
            let previousDuration = previous[location.itemIndex].timelineDuration
            mutateItems(at: location) { items in
                items[location.itemIndex].sourceRange = range
                guard location.trackIndex == 0 else { return }
                let delta = items[location.itemIndex].timelineDuration - previousDuration
                if location.itemIndex + 1 < items.count {
                    for followingIndex in (location.itemIndex + 1)..<items.count {
                        items[followingIndex].timelineStart =
                            items[followingIndex].timelineStart + delta
                    }
                }
            }
            return .setTrackItems(location.trackID, previous)

        case .setSpeed(let id, let speed):
            guard speed.isFinite, (0.25...4).contains(speed) else {
                throw ModelError.invalidSpeed(speed)
            }
            let location = try itemLocation(id)
            try ensureUnlocked(location)
            let previous = items(at: location)
            let previousDuration = previous[location.itemIndex].timelineDuration
            mutateItems(at: location) { items in
                items[location.itemIndex].speed = speed
                guard location.trackIndex == 0 else { return }
                let delta = items[location.itemIndex].timelineDuration - previousDuration
                if location.itemIndex + 1 < items.count {
                    for followingIndex in (location.itemIndex + 1)..<items.count {
                        items[followingIndex].timelineStart =
                            items[followingIndex].timelineStart + delta
                    }
                }
            }
            return .setTrackItems(location.trackID, previous)

        case .setEnabled(let id, let isEnabled):
            let location = try itemLocation(id)
            try ensureUnlocked(location)
            let previous = items(at: location)[location.itemIndex].isEnabled
            mutateItem(at: location) { $0.isEnabled = isEnabled }
            return .setEnabled(id, previous)

        case .addEffect(let itemID, let effect, let requestedIndex):
            let location = try itemLocation(itemID)
            try ensureUnlocked(location)
            let effects = items(at: location)[location.itemIndex].effects
            guard !effects.contains(where: { $0.id == effect.id }) else {
                throw ModelError.duplicateEffect(itemID, effect.id)
            }
            let insertionIndex = requestedIndex ?? effects.count
            guard (0...effects.count).contains(insertionIndex) else {
                throw ModelError.indexOutOfRange(insertionIndex, count: effects.count)
            }
            mutateItem(at: location) { $0.effects.insert(effect, at: insertionIndex) }
            return .removeEffect(itemID, effect.id)

        case .removeEffect(let itemID, let effectID):
            let location = try itemLocation(itemID)
            try ensureUnlocked(location)
            let effects = items(at: location)[location.itemIndex].effects
            guard let effectIndex = effects.firstIndex(where: { $0.id == effectID }) else {
                throw ModelError.effectNotFound(itemID, effectID)
            }
            let removed = effects[effectIndex]
            mutateItem(at: location) { $0.effects.remove(at: effectIndex) }
            return .addEffect(itemID, removed, index: effectIndex)

        case .updateEffect(let itemID, let effect):
            let location = try itemLocation(itemID)
            try ensureUnlocked(location)
            let effects = items(at: location)[location.itemIndex].effects
            guard let effectIndex = effects.firstIndex(where: { $0.id == effect.id }) else {
                throw ModelError.effectNotFound(itemID, effect.id)
            }
            let previous = effects[effectIndex]
            mutateItem(at: location) { $0.effects[effectIndex] = effect }
            return .updateEffect(itemID, previous)

        case .setTrackItems(let trackID, let items):
            if let index = timeline.videoTracks.firstIndex(where: { $0.id == trackID }) {
                guard !timeline.videoTracks[index].isLocked else {
                    throw ModelError.trackLocked(trackID)
                }
                let previous = timeline.videoTracks[index].items
                timeline.videoTracks[index].items = items
                return .setTrackItems(trackID, previous)
            }
            if let index = timeline.audioTracks.firstIndex(where: { $0.id == trackID }) {
                guard !timeline.audioTracks[index].isLocked else {
                    throw ModelError.trackLocked(trackID)
                }
                let previous = timeline.audioTracks[index].items
                timeline.audioTracks[index].items = items
                return .setTrackItems(trackID, previous)
            }
            throw ModelError.trackNotFound(trackID)

        case .setTrack(let track):
            if let index = timeline.videoTracks.firstIndex(where: { $0.id == track.id }) {
                let previous = timeline.videoTracks[index]
                timeline.videoTracks[index] = track
                return .setTrack(previous)
            }
            if let index = timeline.audioTracks.firstIndex(where: { $0.id == track.id }) {
                let previous = timeline.audioTracks[index]
                timeline.audioTracks[index] = track
                return .setTrack(previous)
            }
            throw ModelError.trackNotFound(track.id)

        case .setVideoTracks(let tracks):
            let previous = timeline.videoTracks
            timeline.videoTracks = tracks
            return .setVideoTracks(previous)

        case .setAudioTracks(let tracks):
            let previous = timeline.audioTracks
            timeline.audioTracks = tracks
            return .setAudioTracks(previous)

        case .setMarkers(let markers):
            let previous = timeline.markers
            timeline.markers = markers
            return .setMarkers(previous)

        case .setCaptions(let captions):
            let previous = timeline.captions
            timeline.captions = captions
            return .setCaptions(previous)

        case .setCanvas(let canvas):
            let previous = self.canvas
            self.canvas = canvas
            return .setCanvas(previous)

        case .rename(let name):
            let previous = self.name
            self.name = name
            return .rename(previous)
        }
    }

    private func ensureUnlocked(_ kind: TrackKind) throws {
        let track: Track?
        switch kind {
        case .video: track = timeline.videoTracks.first
        case .audio: track = timeline.audioTracks.first
        }
        if let track, track.isLocked {
            throw ModelError.trackLocked(track.id)
        }
    }

    private func ensureUnlocked(_ location: ItemLocation) throws {
        let track: Track
        switch location.kind {
        case .video:
            track = timeline.videoTracks[location.trackIndex]
        case .audio:
            track = timeline.audioTracks[location.trackIndex]
        }
        if track.isLocked {
            throw ModelError.trackLocked(track.id)
        }
    }

    private func itemLocation(_ id: ItemID) throws -> ItemLocation {
        guard let location = itemLocationIfPresent(id) else {
            throw ModelError.itemNotFound(id)
        }
        return location
    }

    private func itemLocationIfPresent(_ id: ItemID) -> ItemLocation? {
        for (trackIndex, track) in timeline.videoTracks.enumerated() {
            if let itemIndex = track.items.firstIndex(where: { $0.id == id }) {
                return ItemLocation(
                    kind: .video,
                    trackIndex: trackIndex,
                    itemIndex: itemIndex,
                    trackID: track.id
                )
            }
        }
        for (trackIndex, track) in timeline.audioTracks.enumerated() {
            if let itemIndex = track.items.firstIndex(where: { $0.id == id }) {
                return ItemLocation(
                    kind: .audio,
                    trackIndex: trackIndex,
                    itemIndex: itemIndex,
                    trackID: track.id
                )
            }
        }
        return nil
    }

    private func items(for track: TrackKind) -> [TimelineItem] {
        switch track {
        case .video: timeline.video
        case .audio: timeline.audio
        }
    }

    private mutating func mutateItems(
        for track: TrackKind,
        _ mutation: (inout [TimelineItem]) -> Void
    ) {
        switch track {
        case .video: mutation(&timeline.video)
        case .audio: mutation(&timeline.audio)
        }
    }

    private func items(at location: ItemLocation) -> [TimelineItem] {
        switch location.kind {
        case .video:
            timeline.videoTracks[location.trackIndex].items
        case .audio:
            timeline.audioTracks[location.trackIndex].items
        }
    }

    private mutating func mutateItems(
        at location: ItemLocation,
        _ mutation: (inout [TimelineItem]) -> Void
    ) {
        switch location.kind {
        case .video:
            mutation(&timeline.videoTracks[location.trackIndex].items)
        case .audio:
            mutation(&timeline.audioTracks[location.trackIndex].items)
        }
    }

    private mutating func mutateItem(
        at location: ItemLocation,
        _ mutation: (inout TimelineItem) -> Void
    ) {
        switch location.kind {
        case .video:
            mutation(&timeline.videoTracks[location.trackIndex].items[location.itemIndex])
        case .audio:
            mutation(&timeline.audioTracks[location.trackIndex].items[location.itemIndex])
        }
    }
}
