import AIKit
@preconcurrency import AVFoundation
import CoreModel
import Foundation
import LibraryStore
import MediaEngine
import Observation

public enum TimelineTool: String, Sendable, CaseIterable {
    case select
    case razor
}

@MainActor
@Observable
public final class EditorViewModel {
    public private(set) var document: ProjectDocument
    public private(set) var selection: Set<ItemID> = []
    public private(set) var playhead = RationalTime.zero
    public private(set) var isPlaying = false
    public private(set) var playbackRate: Float = 1
    public private(set) var isScrubbing = false
    public private(set) var isBuilding = false
    public private(set) var isExporting = false
    public private(set) var exportProgress = 0.0
    public private(set) var lastExportURL: URL?
    public private(set) var notice: String?
    public private(set) var eventTracks: [AssetID: EventTrack]
    public private(set) var clickTrackingState: ClickTrackingState
    public private(set) var isSnappingEnabled: Bool
    public private(set) var activeTool: TimelineTool = .select
    public private(set) var inPoint: RationalTime?
    public private(set) var outPoint: RationalTime?
    public private(set) var targetedVideoTrackID: TrackID?
    public let undoManager = UndoManager()
    public let player = AVPlayer()

    private var assets: [AssetID: AssetRecord]
    private let resolver: @Sendable (AssetID) async throws -> URL
    private let persistence: @Sendable (ProjectDocument, GraphPatch?) async throws -> Void
    private let buildsPlayback: Bool
    private let exporter = Exporter()
    private var rebuildTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var resumeAfterScrub = false
    private var copiedAttributeSourceID: ItemID?

    public init(
        document: ProjectDocument,
        assets: [AssetID: AssetRecord],
        eventTracks: [AssetID: EventTrack] = [:],
        clickTrackingState: ClickTrackingState = .disabled(
            reason: "Accessibility access is off. Auto-zoom is unavailable."
        ),
        buildsPlayback: Bool = true,
        resolving: @escaping @Sendable (AssetID) async throws -> URL,
        persisting: @escaping @Sendable (ProjectDocument, GraphPatch?) async throws -> Void
    ) {
        self.document = document
        self.assets = assets
        self.eventTracks = eventTracks
        self.clickTrackingState = clickTrackingState
        self.buildsPlayback = buildsPlayback
        self.resolver = resolving
        self.persistence = persisting
        self.isSnappingEnabled =
            UserDefaults.standard.object(forKey: "reel.timeline.snapping") as? Bool ?? true
        self.targetedVideoTrackID = document.timeline.videoTracks.first?.id
        self.undoManager.groupsByEvent = false
    }

    public var duration: RationalTime { document.duration }

    public var selectedItem: TimelineItem? {
        selection.compactMap { document.item($0) }.first
    }

    public var targetedVideoTrack: Track? {
        document.timeline.videoTracks.first { $0.id == targetedVideoTrackID }
    }

    public var selectedLocalTime: RationalTime {
        guard let selectedItem else { return .zero }
        return min(max(playhead - selectedItem.timelineStart, .zero), selectedItem.timelineDuration)
    }

    public var selectedOpacity: Double {
        selectedItem?.opacity.value(at: selectedLocalTime) ?? 1
    }

    public var selectedTransform: Transform2D {
        selectedItem?.transform.value(at: selectedLocalTime) ?? .identity
    }

    public var targetedGain: Double {
        targetedVideoTrack?.gain.value(at: playhead) ?? 0
    }

    public var hasOpacityKeyframeAtPlayhead: Bool {
        selectedItem?.opacity.keyframes.contains { $0.time == selectedLocalTime } == true
    }

    public var hasTransformKeyframeAtPlayhead: Bool {
        selectedItem?.transform.keyframes.contains { $0.time == selectedLocalTime } == true
    }

    public var hasGainKeyframeAtPlayhead: Bool {
        targetedVideoTrack?.gain.keyframes.contains { $0.time == playhead } == true
    }

    public var assetNames: [AssetID: String] {
        assets.mapValues(\.displayName)
    }

    public var assetDurations: [AssetID: RationalTime] {
        assets.compactMapValues(\.duration)
    }

    public var missingAssetIDs: Set<AssetID> {
        Set(assets.values.filter(\.isMissing).map(\.id))
    }

    public var availableVideoAssets: [AssetRecord] {
        assets.values.filter { $0.kind == .video }
            .sorted { $0.importedAt < $1.importedAt }
    }

    public func assistantContextDigest() -> ContextDigest {
        let items = document.timeline.video.map { item in
            let asset = assets[item.assetID]
            let track = eventTracks[item.assetID]
            let alignment: String
            switch track?.alignment {
            case .exact: alignment = "exact"
            case .estimated: alignment = "estimated"
            case .unavailable: alignment = "unavailable"
            case nil: alignment = asset?.eventAlignment?.rawValue ?? "unavailable"
            }
            let effectCounts = Dictionary(grouping: item.effects, by: { effectName($0.kind) })
                .map { "\($0.key)×\($0.value.count)" }.sorted()
            return ContextItem(
                id: item.id.rawValue,
                name: asset?.displayName ?? "Clip",
                duration: item.timelineDuration.seconds,
                hasAudio: asset?.hasAudio ?? false,
                clicks: track?.clicks.count ?? 0,
                effects: effectCounts,
                alignment: alignment
            )
        }
        return ContextDigest(
            projectName: document.name,
            duration: document.duration.seconds,
            canvas:
                "\(document.canvas.width)x\(document.canvas.height)@\(document.canvas.frameRate.framesPerSecond.formatted())",
            selectedItemID: selectedItem?.id.rawValue,
            items: items
        )
    }

    public func toolExecutionContext() -> ToolExecutionContext {
        ToolExecutionContext(
            document: document,
            assets: assets,
            eventTracks: eventTracks,
            selectedItemIDs: selection,
            playhead: playhead,
            resolving: resolver
        )
    }

    public var timelineClickMarkers: [TimelineClickMarker] {
        var markers: [TimelineClickMarker] = []
        for videoTrack in document.timeline.videoTracks {
            for item in videoTrack.items {
                if let track = eventTracks[item.assetID] {
                    for (index, click) in track.clicks.enumerated()
                    where click.time >= item.sourceRange.start && click.time < item.sourceRange.end
                    {
                        let localTime = (click.time - item.sourceRange.start).scaled(
                            by: 1 / item.speed
                        )
                        markers.append(
                            TimelineClickMarker(
                                id: "\(item.id.rawValue)-\(index)-\(click.time.value)",
                                itemID: item.id,
                                timelineTime: item.timelineStart + localTime,
                                sourceTime: click.time,
                                point: click.point,
                                button: click.button,
                                clickCount: click.clickCount
                            )
                        )
                    }
                }
            }
        }
        return markers
    }

    public var selectedClickCount: Int {
        guard let item = selectedItem else { return 0 }
        return eventTracks[item.assetID]?.clicks.count {
            $0.time >= item.sourceRange.start && $0.time < item.sourceRange.end
        } ?? 0
    }

    public var selectedAlignmentDescription: String {
        guard let item = selectedItem, let track = eventTracks[item.assetID] else {
            return "None"
        }
        switch track.alignment {
        case .exact: return "Exact"
        case .estimated(_, let confidence):
            return "Estimated \(Int((confidence * 100).rounded()))%"
        case .unavailable: return "Unavailable"
        }
    }

    public var autoZoomUnavailableReason: String? {
        guard let item = selectedItem else { return "Select a clip first." }
        guard clickTrackingState.isEnabled else {
            if case .disabled(let reason) = clickTrackingState { return reason }
            return "Click tracking is still starting."
        }
        guard let track = eventTracks[item.assetID] else {
            return "This clip has no click track."
        }
        if case .unavailable(let reason) = track.alignment { return reason }
        guard selectedClickCount > 0 else { return "This clip has no recorded clicks." }
        return nil
    }

    public func start() {
        rebuild(quality: .full)
    }

    public func stop() {
        pause()
        rebuildTask?.cancel()
        rebuildTask = nil
        exportTask?.cancel()
        exportTask = nil
    }

    public func setEventTracks(_ tracks: [AssetID: EventTrack]) {
        eventTracks = tracks
    }

    public func setClickTrackingState(_ state: ClickTrackingState) {
        clickTrackingState = state
    }

    public func perform(_ patch: GraphPatch) throws {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
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

    public func selectTool(_ tool: TimelineTool) {
        activeTool = tool
    }

    public func toggleSnapping() {
        isSnappingEnabled.toggle()
        UserDefaults.standard.set(isSnappingEnabled, forKey: "reel.timeline.snapping")
        notice = isSnappingEnabled ? "Snapping on." : "Snapping off."
    }

    public func shuttleBackward() {
        let next: Float
        switch playbackRate {
        case ...(-2): next = -4
        case ..<0: next = playbackRate * 2
        default: next = -1
        }
        startPlayback(rate: next)
    }

    public func shuttlePause() {
        pause()
        playbackRate = 0
    }

    public func shuttleForward() {
        let next: Float
        switch playbackRate {
        case 2...: next = 4
        case 1...: next = playbackRate * 2
        default: next = 1
        }
        startPlayback(rate: next)
    }

    public func setInPoint() {
        inPoint = playhead
        if let outPoint, outPoint < playhead { self.outPoint = nil }
        notice = "In point set at \(playhead.seconds.formatted())s."
    }

    public func setOutPoint() {
        outPoint = playhead
        if let inPoint, inPoint > playhead { self.inPoint = nil }
        notice = "Out point set at \(playhead.seconds.formatted())s."
    }

    public func addMarkerAtPlayhead() {
        let marker = Marker(
            id: .generate(),
            name: "Marker \(document.timeline.markers.count + 1)",
            time: playhead
        )
        do {
            try perform(TimelineEditPlanner.addMarker(to: document, marker: marker))
        } catch {
            notice = "The marker could not be added."
        }
    }

    public func goToNextMarker() {
        let markers = document.timeline.markers.sorted { $0.time < $1.time }
        guard !markers.isEmpty else {
            notice = "This project has no markers."
            return
        }
        seek(to: markers.first(where: { $0.time > playhead })?.time ?? markers[0].time)
    }

    public func rippleDeleteSelected() {
        guard let itemID = selectedItem?.id else {
            notice = "Select a V1 clip to ripple delete."
            return
        }
        do {
            try perform(TimelineEditPlanner.rippleDelete(in: document, itemID: itemID))
            selection.remove(itemID)
        } catch {
            notice = "The clip could not be ripple deleted."
        }
    }

    public func rollSelected(by delta: RationalTime? = nil) {
        guard let selectedItem else { return }
        let amount = delta ?? document.canvas.frameRate.frameDuration
        do {
            try perform(
                TimelineEditPlanner.rollEdit(
                    in: document,
                    leftItemID: selectedItem.id,
                    by: amount,
                    assetDurations: assetDurations
                )
            )
        } catch {
            notice = "Select the clip left of a valid cut to roll it."
        }
    }

    public func slipSelected(by delta: RationalTime? = nil) {
        guard let selectedItem, let duration = assetDurations[selectedItem.assetID] else { return }
        do {
            try perform(
                TimelineEditPlanner.slipClip(
                    in: document,
                    itemID: selectedItem.id,
                    by: delta ?? document.canvas.frameRate.frameDuration,
                    assetDuration: duration
                )
            )
        } catch {
            notice = "The source has no more media in that direction."
        }
    }

    public func slideSelected(by delta: RationalTime? = nil) {
        guard let selectedItem else { return }
        do {
            try perform(
                TimelineEditPlanner.slideClip(
                    in: document,
                    itemID: selectedItem.id,
                    by: delta ?? document.canvas.frameRate.frameDuration,
                    assetDurations: assetDurations
                )
            )
        } catch {
            notice = "Slide requires editable clips on both sides."
        }
    }

    public func addCrossDissolve() {
        guard let selectedItem else { return }
        do {
            try perform(
                TimelineEditPlanner.crossDissolve(
                    in: document,
                    leftItemID: selectedItem.id,
                    duration: RationalTime(seconds: 0.35)
                )
            )
        } catch {
            notice = "Select the clip left of a cut with enough media."
        }
    }

    public func addAudioFade() {
        guard let selectedItem else { return }
        do {
            try perform(
                TimelineEditPlanner.setAudioFade(
                    in: document,
                    itemID: selectedItem.id,
                    fadeIn: RationalTime(seconds: min(0.25, selectedItem.timelineDuration.seconds)),
                    fadeOut: RationalTime(seconds: min(0.25, selectedItem.timelineDuration.seconds))
                )
            )
        } catch {
            notice = "The audio fade could not be applied."
        }
    }

    public func copySelectedAttributes() {
        copiedAttributeSourceID = selectedItem?.id
        notice =
            copiedAttributeSourceID == nil ? "Select a source clip first." : "Attributes copied."
    }

    public func pasteAttributesToSelection() {
        guard let sourceID = copiedAttributeSourceID, !selection.isEmpty else {
            notice = "Copy attributes, then select destination clips."
            return
        }
        do {
            try perform(
                TimelineEditPlanner.pasteAttributes(
                    from: sourceID,
                    to: Array(selection),
                    in: document
                )
            )
        } catch {
            notice = "The attributes could not be pasted."
        }
    }

    public func cycleTargetVideoTrack() {
        let tracks = document.timeline.videoTracks
        guard !tracks.isEmpty else { return }
        let current = tracks.firstIndex { $0.id == targetedVideoTrackID } ?? -1
        targetedVideoTrackID = tracks[(current + 1) % tracks.count].id
        notice = "Targeting \(tracks[(current + 1) % tracks.count].name)."
    }

    public func toggleTargetTrackEnabled() {
        updateTargetTrack { $0.isEnabled.toggle() }
    }

    public func toggleTargetTrackLocked() {
        updateTargetTrack { $0.isLocked.toggle() }
    }

    public func toggleTargetTrackMuted() {
        updateTargetTrack { $0.isMuted.toggle() }
    }

    public func toggleTargetTrackSolo() {
        updateTargetTrack { $0.isSolo.toggle() }
    }

    public func setSelectedOpacity(_ value: Double) {
        guard let selectedItem else { return }
        if selectedItem.opacity.keyframes.isEmpty {
            updateItem(selectedItem.id, label: "Set Opacity") {
                $0.opacity.constant = value
            }
        } else {
            setOpacityKeyframe(value)
        }
    }

    public func setOpacityKeyframe(_ value: Double? = nil) {
        guard let selectedItem else { return }
        do {
            try perform(
                TimelineEditPlanner.setOpacityKeyframe(
                    in: document,
                    itemID: selectedItem.id,
                    at: selectedLocalTime,
                    value: value ?? selectedOpacity
                )
            )
        } catch {
            notice = "The opacity keyframe could not be set."
        }
    }

    public func setSelectedScale(_ scale: Double) {
        guard let selectedItem else { return }
        var transform = selectedTransform
        transform.scaleX = scale
        transform.scaleY = scale
        if selectedItem.transform.keyframes.isEmpty {
            updateItem(selectedItem.id, label: "Set Scale") {
                $0.transform.constant = transform
            }
        } else {
            setTransformKeyframe(transform)
        }
    }

    public func setTransformKeyframe(_ value: Transform2D? = nil) {
        guard let selectedItem else { return }
        do {
            try perform(
                TimelineEditPlanner.setTransformKeyframe(
                    in: document,
                    itemID: selectedItem.id,
                    at: selectedLocalTime,
                    value: value ?? selectedTransform
                )
            )
        } catch {
            notice = "The transform keyframe could not be set."
        }
    }

    public func setTargetedGain(_ decibels: Double) {
        guard let track = targetedVideoTrack else { return }
        if track.gain.keyframes.isEmpty {
            updateTargetTrack { $0.gain.constant = decibels }
        } else {
            setGainKeyframe(decibels)
        }
    }

    public func setGainKeyframe(_ decibels: Double? = nil) {
        guard let track = targetedVideoTrack else { return }
        do {
            try perform(
                TimelineEditPlanner.setGainKeyframe(
                    in: document,
                    trackID: track.id,
                    at: playhead,
                    decibels: decibels ?? targetedGain
                )
            )
        } catch {
            notice = "The gain keyframe could not be set."
        }
    }

    public func setEffectKeyframe(_ effect: Effect) {
        guard let selectedItem else { return }
        do {
            let patch: GraphPatch
            switch effect {
            case .blur(let blur):
                patch = try TimelineEditPlanner.setBlurIntensityKeyframe(
                    in: document,
                    itemID: selectedItem.id,
                    effectID: blur.id,
                    at: selectedLocalTime.scaled(by: selectedItem.speed),
                    value: blur.intensity(
                        at: selectedLocalTime.scaled(by: selectedItem.speed)
                    )
                )
            case .zoom(let zoom):
                patch = try TimelineEditPlanner.setZoomScaleKeyframe(
                    in: document,
                    itemID: selectedItem.id,
                    effectID: zoom.id,
                    at: selectedLocalTime.scaled(by: selectedItem.speed),
                    value: zoom.scaleAnimation.value(
                        at: selectedLocalTime.scaled(by: selectedItem.speed)
                    )
                )
            default:
                notice = "This effect has no numeric keyframe control."
                return
            }
            try perform(patch)
        } catch {
            notice = "The effect keyframe could not be set."
        }
    }

    public func insertSelectedSource(overwrite: Bool) {
        guard let source = selectedItem,
            let trackID = targetedVideoTrackID ?? document.timeline.videoTracks.first?.id
        else {
            notice = "Select a source clip first."
            return
        }
        var inserted = source
        inserted.id = .generate()
        inserted.effects = []
        inserted.timelineStart = playhead
        if let inPoint, let outPoint, outPoint > inPoint {
            inserted.sourceRange.duration = min(
                inserted.sourceRange.duration,
                outPoint - inPoint
            )
        }
        do {
            let patch =
                overwrite
                ? try TimelineEditPlanner.overwrite(
                    in: document,
                    item: inserted,
                    on: trackID,
                    at: playhead,
                    splitRightItemID: .generate()
                )
                : try TimelineEditPlanner.rippleInsert(
                    in: document,
                    item: inserted,
                    on: trackID,
                    at: playhead
                )
            try perform(patch)
            selection = [inserted.id]
        } catch {
            notice =
                overwrite
                ? "The overwrite edit could not be applied."
                : "Snap the playhead to an edge before inserting."
        }
    }

    public func splitAtPlayhead() {
        guard let itemID = selectedItem?.id ?? document.item(at: playhead)?.item.id else {
            notice = "Move the playhead over a clip before splitting."
            return
        }
        split(itemID, at: playhead)
    }

    public func split(_ itemID: ItemID, at time: RationalTime) {
        do {
            try perform(
                TimelineEditPlanner.splitClip(
                    in: document,
                    itemID: itemID,
                    at: time,
                    rightItemID: .generate()
                )
            )
            seek(to: time)
            if let right = document.item(at: time)?.item.id {
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

    public func addZoom(to itemID: ItemID) {
        guard let item = document.item(itemID) else { return }
        addEffect(
            .zoom(
                ZoomEffect(
                    id: .generate(),
                    range: item.effectRange,
                    center: NormalizedPoint(x: 0.5, y: 0.5),
                    scale: 1.85
                )
            ),
            to: itemID
        )
    }

    public func autoZoomSelectedClip() {
        guard let item = selectedItem,
            autoZoomUnavailableReason == nil,
            let track = eventTracks[item.assetID]
        else {
            notice = autoZoomUnavailableReason ?? "Auto-zoom is unavailable."
            return
        }
        let generated = AutoZoomGenerator().zooms(for: track, item: item)
        guard !generated.isEmpty else {
            notice = "No click clusters were found in the selected range."
            return
        }
        let removals = item.effects.reversed().compactMap { effect -> GraphOp? in
            guard case .zoom(let zoom) = effect, zoom.source == .derivedFromClicks else {
                return nil
            }
            return .removeEffect(item.id, zoom.id)
        }
        let additions = generated.map { GraphOp.addEffect(item.id, .zoom($0)) }
        do {
            try perform(
                GraphPatch(
                    ops: removals + additions,
                    label: "Zoom on Clicks",
                    origin: .user
                )
            )
            notice = "Added \(generated.count) click zoom\(generated.count == 1 ? "" : "s")."
        } catch {
            notice = "Click zooms could not be applied."
        }
    }

    public func addBackground(to itemID: ItemID) {
        guard let item = document.item(itemID) else { return }
        addEffect(
            .background(
                BackgroundEffect(
                    id: .generate(),
                    range: item.effectRange,
                    padding: 0.06,
                    cornerRadius: 24,
                    style: .solid(.black),
                    shadow: ShadowSpec(
                        color: RGBA(r: 0, g: 0, b: 0, a: 0.4),
                        radius: 18,
                        offsetX: 0,
                        offsetY: 8
                    )
                )
            ),
            to: itemID
        )
    }

    public func addCrop(to itemID: ItemID) {
        guard let item = document.item(itemID) else { return }
        addEffect(
            .crop(
                CropEffect(
                    id: .generate(),
                    range: item.effectRange,
                    rect: NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
                )
            ),
            to: itemID
        )
    }

    public func addBlur(to itemID: ItemID) {
        guard let item = document.item(itemID) else { return }
        addEffect(
            .blur(
                BlurEffect(
                    id: .generate(),
                    range: item.effectRange,
                    regions: [
                        TimedRegion(
                            time: .zero,
                            rect: NormalizedRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
                        )
                    ],
                    mode: .gaussian(radius: 18),
                    isDestructiveOnExport: true
                )
            ),
            to: itemID
        )
    }

    public func removeEffect(_ effectID: EffectID, from itemID: ItemID) {
        do {
            try perform(
                GraphPatch(
                    ops: [.removeEffect(itemID, effectID)],
                    label: "Remove Effect",
                    origin: .user
                )
            )
        } catch {
            notice = "The effect could not be removed."
        }
    }

    public func export(to url: URL, preset: ExportPreset) {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0
        lastExportURL = nil
        let document = document
        let resolver = resolver
        let exporter = exporter
        exportTask = Task { [weak self] in
            do {
                let updates = await exporter.export(
                    document,
                    preset: preset,
                    to: url,
                    resolving: resolver
                )
                for try await update in updates {
                    guard let self else { return }
                    exportProgress = update.fraction
                }
                guard let self else { return }
                lastExportURL = url
                isExporting = false
                notice = "Exported \(url.lastPathComponent)."
            } catch MediaEngineError.cancelled {
                self?.isExporting = false
                self?.notice = "Export cancelled."
            } catch {
                self?.isExporting = false
                self?.notice = error.localizedDescription
            }
        }
    }

    public func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
    }

    @discardableResult
    public func insert(_ asset: AssetRecord) -> Bool {
        guard asset.kind == .video, let duration = asset.duration else {
            notice = "That asset has no playable duration."
            return false
        }
        let previousAsset = assets.updateValue(asset, forKey: asset.id)
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
            return true
        } catch {
            if let previousAsset {
                assets[asset.id] = previousAsset
            } else {
                assets.removeValue(forKey: asset.id)
            }
            notice = "The clip could not be added."
            return false
        }
    }

    @discardableResult
    public func appendCapturedAsset(
        _ asset: AssetRecord,
        eventTrack: EventTrack? = nil
    ) -> Bool {
        guard !document.timeline.video.contains(where: { $0.assetID == asset.id }) else {
            notice = "That recording is already in this timeline."
            return false
        }
        guard insert(asset) else { return false }
        if let eventTrack {
            eventTracks[asset.id] = eventTrack
        }
        if let inserted = selectedItem {
            seek(to: inserted.timelineStart)
        }
        notice = "Added \(asset.displayName) to the end of the timeline."
        return true
    }

    public func clearNotice() {
        notice = nil
    }

    private func addEffect(_ effect: Effect, to itemID: ItemID) {
        do {
            try perform(
                GraphPatch(
                    ops: [.addEffect(itemID, effect)],
                    label: "Add Effect",
                    origin: .user
                )
            )
        } catch {
            notice = "The effect could not be added."
        }
    }

    private func updateTargetTrack(_ mutation: (inout Track) -> Void) {
        guard var track = targetedVideoTrack else { return }
        mutation(&track)
        do {
            try perform(
                GraphPatch(
                    ops: [.setTrack(track)],
                    label: "Change Track State",
                    origin: .user
                )
            )
        } catch {
            notice = "The track state could not be changed."
        }
    }

    private func updateItem(
        _ id: ItemID,
        label: String,
        mutation: (inout TimelineItem) -> Void
    ) {
        for track in document.timeline.videoTracks + document.timeline.audioTracks {
            guard let index = track.items.firstIndex(where: { $0.id == id }) else { continue }
            var items = track.items
            mutation(&items[index])
            do {
                try perform(
                    GraphPatch(
                        ops: [.setTrackItems(track.id, items)],
                        label: label,
                        origin: .user
                    )
                )
            } catch {
                notice = "The keyframe value could not be changed."
            }
            return
        }
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
                if isPlaying { player.playImmediately(atRate: playbackRate) }
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
        startPlayback(rate: 1)
    }

    private func startPlayback(rate: Float) {
        guard duration > .zero else { return }
        if rate > 0, playhead >= duration { seek(to: .zero) }
        if rate < 0, playhead <= .zero { seek(to: duration) }
        playbackRate = rate
        player.playImmediately(atRate: rate)
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, isPlaying else { return }
                playhead = min(player.currentTime().rational, duration)
                if playhead >= duration || playhead <= .zero && playbackRate < 0 {
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

private func effectName(_ kind: EffectKind) -> String {
    switch kind {
    case .zoom: "zoom"
    case .crop: "crop"
    case .background: "background"
    case .blur: "blur"
    case .cursor: "cursor"
    case .text: "text"
    case .unknown(let name): name
    }
}

extension TimelineItem {
    fileprivate var effectRange: TimeRange {
        TimeRange(start: .zero, duration: sourceRange.duration)
    }
}
