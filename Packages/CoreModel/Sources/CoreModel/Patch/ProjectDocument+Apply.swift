import Foundation

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
            inverseOperations.append(try candidate.apply(operation))
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
            guard self.item(item.id) == nil else {
                throw ModelError.duplicateItem(item.id)
            }
            let count = items(for: track).count
            guard (0...count).contains(index) else {
                throw ModelError.indexOutOfRange(index, count: count)
            }
            mutateItems(for: track) { $0.insert(item, at: index) }
            return .removeItem(item.id)

        case .removeItem(let id):
            let location = try itemLocation(id)
            let removed = items(for: location.track)[location.index]
            mutateItems(for: location.track) { $0.remove(at: location.index) }
            return .insertItem(removed, track: location.track, index: location.index)

        case .moveItem(let id, let destination):
            let location = try itemLocation(id)
            let count = items(for: location.track).count
            guard (0..<count).contains(destination) else {
                throw ModelError.indexOutOfRange(destination, count: count)
            }
            mutateItems(for: location.track) { items in
                let moved = items.remove(at: location.index)
                items.insert(moved, at: destination)
            }
            return .moveItem(id, toIndex: location.index)

        case .setSourceRange(let id, let range):
            let location = try itemLocation(id)
            let previous = items(for: location.track)[location.index].sourceRange
            mutateItem(at: location) { $0.sourceRange = range }
            return .setSourceRange(id, previous)

        case .setSpeed(let id, let speed):
            guard speed.isFinite, (0.25...4).contains(speed) else {
                throw ModelError.invalidSpeed(speed)
            }
            let location = try itemLocation(id)
            let previous = items(for: location.track)[location.index].speed
            mutateItem(at: location) { $0.speed = speed }
            return .setSpeed(id, previous)

        case .setEnabled(let id, let isEnabled):
            let location = try itemLocation(id)
            let previous = items(for: location.track)[location.index].isEnabled
            mutateItem(at: location) { $0.isEnabled = isEnabled }
            return .setEnabled(id, previous)

        case .addEffect(let itemID, let effect, let requestedIndex):
            let location = try itemLocation(itemID)
            let effects = items(for: location.track)[location.index].effects
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
            let effects = items(for: location.track)[location.index].effects
            guard let effectIndex = effects.firstIndex(where: { $0.id == effectID }) else {
                throw ModelError.effectNotFound(itemID, effectID)
            }
            let removed = effects[effectIndex]
            mutateItem(at: location) { $0.effects.remove(at: effectIndex) }
            return .addEffect(itemID, removed, index: effectIndex)

        case .updateEffect(let itemID, let effect):
            let location = try itemLocation(itemID)
            let effects = items(for: location.track)[location.index].effects
            guard let effectIndex = effects.firstIndex(where: { $0.id == effect.id }) else {
                throw ModelError.effectNotFound(itemID, effect.id)
            }
            let previous = effects[effectIndex]
            mutateItem(at: location) { $0.effects[effectIndex] = effect }
            return .updateEffect(itemID, previous)

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

    private func itemLocation(_ id: ItemID) throws -> (track: TrackKind, index: Int) {
        if let index = timeline.video.firstIndex(where: { $0.id == id }) {
            return (.video, index)
        }
        if let index = timeline.audio.firstIndex(where: { $0.id == id }) {
            return (.audio, index)
        }
        throw ModelError.itemNotFound(id)
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

    private mutating func mutateItem(
        at location: (track: TrackKind, index: Int),
        _ mutation: (inout TimelineItem) -> Void
    ) {
        switch location.track {
        case .video: mutation(&timeline.video[location.index])
        case .audio: mutation(&timeline.audio[location.index])
        }
    }
}
