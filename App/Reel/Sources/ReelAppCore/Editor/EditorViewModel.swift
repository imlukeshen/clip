@preconcurrency import AVFoundation
import CoreModel
import Foundation
import LibraryStore
import MediaEngine
import Observation

@MainActor
@Observable
public final class EditorViewModel {
    public private(set) var document: ProjectDocument
    public private(set) var selection: Set<ItemID> = []
    public private(set) var playhead = RationalTime.zero
    public private(set) var isPlaying = false
    public private(set) var isScrubbing = false
    public private(set) var isBuilding = false
    public private(set) var notice: String?
    public let undoManager = UndoManager()
    public let player = AVPlayer()

    private var assets: [AssetID: AssetRecord]
    private let resolver: @Sendable (AssetID) async throws -> URL
    private let persistence: @Sendable (ProjectDocument, GraphPatch?) async throws -> Void
    private let buildsPlayback: Bool
    private var rebuildTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var resumeAfterScrub = false

    public init(
        document: ProjectDocument,
        assets: [AssetID: AssetRecord],
        buildsPlayback: Bool = true,
        resolving: @escaping @Sendable (AssetID) async throws -> URL,
        persisting: @escaping @Sendable (ProjectDocument, GraphPatch?) async throws -> Void
    ) {
        self.document = document
        self.assets = assets
        self.buildsPlayback = buildsPlayback
        self.resolver = resolving
        self.persistence = persisting
    }

    public var duration: RationalTime { document.duration }

    public var selectedItem: TimelineItem? {
        selection.compactMap { document.item($0) }.first
    }

    public var assetNames: [AssetID: String] {
        assets.mapValues(\.displayName)
    }

    public var assetDurations: [AssetID: RationalTime] {
        assets.compactMapValues(\.duration)
    }

    public var availableVideoAssets: [AssetRecord] {
        assets.values.filter { $0.kind == .video }
            .sorted { $0.importedAt < $1.importedAt }
    }

    public func start() {
        rebuild(quality: .full)
    }

    public func stop() {
        pause()
        rebuildTask?.cancel()
        rebuildTask = nil
    }

    public func perform(_ patch: GraphPatch) throws {
        try apply(patch, registeringUndo: true)
    }

    public func undo() {
        undoManager.undo()
    }

    public func redo() {
        undoManager.redo()
    }

    public func select(_ itemID: ItemID, extending: Bool = false) {
        if extending {
            if !selection.insert(itemID).inserted {
                selection.remove(itemID)
            }
        } else {
            selection = [itemID]
        }
    }

    public func selectItem(at time: RationalTime) {
        if let item = document.item(at: time)?.item {
            selection = [item.id]
        }
    }

    public func seek(to time: RationalTime, exact: Bool = true) {
        playhead = min(max(time, .zero), duration)
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.08, preferredTimescale: 600)
        player.seek(
            to: playhead.cmTime,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    public func setScrubbing(_ scrubbing: Bool) {
        guard isScrubbing != scrubbing else { return }
        isScrubbing = scrubbing
        if scrubbing {
            resumeAfterScrub = isPlaying
            pause()
            rebuild(quality: .proxy(720))
        } else {
            rebuild(quality: .full)
            if resumeAfterScrub { play() }
            resumeAfterScrub = false
        }
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func splitAtPlayhead() {
        guard let itemID = selectedItem?.id ?? document.item(at: playhead)?.item.id else {
            notice = "Move the playhead over a clip before splitting."
            return
        }
        do {
            try perform(
                TimelineEditPlanner.splitClip(
                    in: document,
                    itemID: itemID,
                    at: playhead,
                    rightItemID: .generate()
                )
            )
            if let right = document.item(at: playhead)?.item.id {
                selection = [right]
            }
        } catch ModelError.splitTooCloseToBoundary {
            notice = "Split at least 0.4 seconds from a clip boundary."
        } catch {
            notice = "The clip could not be split."
        }
    }

    public func reorder(_ itemID: ItemID, to index: Int) {
        do {
            try perform(TimelineEditPlanner.reorderClip(itemID, toIndex: index))
        } catch {
            notice = "The clip could not be moved."
        }
    }

    public func trim(_ itemID: ItemID, to range: TimeRange) {
        guard let item = document.item(itemID),
            let duration = assets[item.assetID]?.duration
        else {
            notice = "The source duration is unavailable."
            return
        }
        do {
            try perform(
                TimelineEditPlanner.trimClip(
                    in: document,
                    itemID: itemID,
                    to: range,
                    assetDuration: duration
                )
            )
        } catch {
            notice = "The clip could not be trimmed."
        }
    }

    public func setSpeed(_ speed: Double, for itemID: ItemID) {
        do {
            try perform(TimelineEditPlanner.setSpeed(of: itemID, to: speed))
        } catch {
            notice = "Choose a speed between 0.25× and 4×."
        }
    }

    public func insert(_ asset: AssetRecord) {
        guard asset.kind == .video, let duration = asset.duration else {
            notice = "That asset has no playable duration."
            return
        }
        assets[asset.id] = asset
        let item = TimelineItem(
            id: .generate(),
            assetID: asset.id,
            sourceRange: TimeRange(start: .zero, duration: duration)
        )
        do {
            try perform(
                GraphPatch(
                    ops: [
                        .insertItem(
                            item,
                            track: .video,
                            index: document.timeline.video.count
                        )
                    ],
                    label: "Add Clip",
                    origin: .user
                )
            )
            selection = [item.id]
        } catch {
            notice = "The clip could not be added."
        }
    }

    public func clearNotice() {
        notice = nil
    }

    private func apply(_ patch: GraphPatch, registeringUndo: Bool) throws {
        var candidate = document
        let inverse = try candidate.apply(patch)
        document = candidate
        selection = selection.filter { document.item($0) != nil }
        playhead = min(playhead, duration)

        if registeringUndo {
            registerUndo(inverse)
            undoManager.setActionName(patch.label)
        }
        persist(inverse: inverse)
        rebuild(quality: isScrubbing ? .proxy(720) : .full)
    }

    private func registerUndo(_ patch: GraphPatch) {
        undoManager.registerUndo(withTarget: self) { target in
            do {
                var candidate = target.document
                let redo = try candidate.apply(patch)
                target.document = candidate
                target.registerUndo(redo)
                target.undoManager.setActionName(patch.label)
                target.selection = target.selection.filter { target.document.item($0) != nil }
                target.playhead = min(target.playhead, target.duration)
                target.persist(inverse: redo)
                target.rebuild(quality: .full)
            } catch {
                target.notice = "Undo could not restore the previous edit."
            }
        }
    }

    private func persist(inverse: GraphPatch?) {
        let document = document
        let persistence = persistence
        let precedingTask = persistenceTask
        persistenceTask = Task { [weak self] in
            _ = await precedingTask?.result
            do {
                try await persistence(document, inverse)
            } catch {
                self?.notice = "The project could not be saved."
            }
        }
    }

    private func rebuild(quality: RenderQuality) {
        guard buildsPlayback else { return }
        rebuildTask?.cancel()
        let document = document
        let resolver = resolver
        isBuilding = true
        rebuildTask = Task { [weak self] in
            do {
                let built = try await CompositionBuilder().build(
                    document,
                    resolving: resolver,
                    quality: quality
                )
                try Task.checkCancellation()
                guard let self else { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                player.replaceCurrentItem(with: item)
                seek(to: playhead)
                if isPlaying { player.play() }
                isBuilding = false
            } catch is CancellationError {
                // A newer document build superseded this one.
            } catch {
                guard let self else { return }
                isBuilding = false
                notice = error.localizedDescription
            }
        }
    }

    private func play() {
        guard duration > .zero else { return }
        if playhead >= duration { seek(to: .zero) }
        player.play()
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, isPlaying else { return }
                playhead = min(player.currentTime().rational, duration)
                if playhead >= duration {
                    pause()
                    return
                }
            }
        }
    }

    private func pause() {
        player.pause()
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }
}
