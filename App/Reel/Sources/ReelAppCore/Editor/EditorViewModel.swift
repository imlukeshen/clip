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

public struct EditorSourceMoment: Sendable, Equatable, Hashable {
    public var assetID: AssetID
    public var time: RationalTime

    public init(assetID: AssetID, time: RationalTime) {
        self.assetID = assetID
        self.time = time
    }
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

    public var timelineMediaCount: Int {
        document.timeline.videoTracks.reduce(0) { $0 + $1.items.count }
            + document.timeline.audioTracks.reduce(0) { $0 + $1.items.count }
    }

    public var isTimelineEmpty: Bool { timelineMediaCount == 0 }

    public var selectedItem: TimelineItem? {
        for item in document.timeline.videoTracks.flatMap(\.items) where selection.contains(item.id)
        {
            return item
        }
        for item in document.timeline.audioTracks.flatMap(\.items) where selection.contains(item.id)
        {
            return item
        }
        return nil
    }

    public var selectedTrackKind: TrackKind? {
        guard let itemID = selectedItem?.id else { return nil }
        if document.timeline.videoTracks.contains(where: { track in
            track.items.contains(where: { $0.id == itemID })
        }) {
            return .video
        }
        if document.timeline.audioTracks.contains(where: { track in
            track.items.contains(where: { $0.id == itemID })
        }) {
            return .audio
        }
        return nil
    }

    public var selectedTrackName: String? {
        guard let itemID = selectedItem?.id else { return nil }
        return (document.timeline.videoTracks + document.timeline.audioTracks)
            .first(where: { track in track.items.contains(where: { $0.id == itemID }) })?.name
    }

    public var selectedNestID: String? { selectedItem?.nestID }

    public var canNestSelection: Bool { selection.count > 1 }

    public var canSeparateSelectedAudio: Bool {
        guard selectedTrackKind == .video, let item = selectedItem else { return false }
        return assets[item.assetID]?.hasAudio == true
    }

    public var canRippleDeleteSelected: Bool {
        guard let itemID = selectedItem?.id else { return false }
        return document.timeline.videoTracks.first?.items.contains(where: { $0.id == itemID })
            == true
    }

    public var targetedVideoTrack: Track? {
        document.timeline.videoTracks.first { $0.id == targetedVideoTrackID }
    }

    public var selectedLocalTime: RationalTime {
        guard let selectedItem else { return .zero }
        return min(max(playhead - selectedItem.timelineStart, .zero), selectedItem.timelineDuration)
    }

    /// The immutable source asset and source-local time visible at the playhead.
    public var sourceMomentAtPlayhead: EditorSourceMoment? {
        guard let location = document.item(at: playhead) else { return nil }
        return EditorSourceMoment(
            assetID: location.item.assetID,
            time: location.item.sourceRange.start + location.local.scaled(by: location.item.speed)
        )
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

    public var availableAudioAssets: [AssetRecord] {
        assets.values.filter { $0.kind == .audio }
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

    /// Renames the project through the same durable, undoable graph path as a
    /// timeline edit. Project packages are keyed by ID, so every Unicode name is
    /// safe as long as it is a useful single-line label.
    @discardableResult
    public func renameProject(to proposedName: String) -> Bool {
        let normalized =
            proposedName
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            notice = "A project name cannot be empty."
            return false
        }
        guard normalized.count <= 200 else {
            notice = "Keep the project name under 200 characters."
            return false
        }
        guard normalized != document.name else { return true }
        do {
            try perform(
                GraphPatch(
                    ops: [.rename(normalized)],
                    label: "Rename Project",
                    origin: .user
                )
            )
            notice = "Project renamed."
            return true
        } catch {
            notice = "The project could not be renamed."
            return false
        }
    }

    public func undo() {
        undoManager.undo()
    }

    public func redo() {
        undoManager.redo()
    }

    public func select(_ itemID: ItemID, extending: Bool = false) {
        let related = nestedItemIDs(containing: itemID)
        if extending {
            if related.isSubset(of: selection) {
                selection.subtract(related)
            } else {
                selection.formUnion(related)
            }
        } else {
            selection = related
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

    /// Removes exactly the selected video and/or audio items without moving
    /// neighbouring media. Nested selections are selected and deleted together.
    public func deleteSelected() {
        guard !selection.isEmpty else {
            notice = "Select video or audio to delete."
            return
        }
        let deleting = selection
        var videoTracks = document.timeline.videoTracks
        var audioTracks = document.timeline.audioTracks
        let affectedTracks = (videoTracks + audioTracks).filter { track in
            track.items.contains(where: { deleting.contains($0.id) })
        }
        guard affectedTracks.allSatisfy({ !$0.isLocked }) else {
            notice = "Unlock the selected track before deleting media."
            return
        }
        for index in videoTracks.indices {
            videoTracks[index].items.removeAll { deleting.contains($0.id) }
        }
        for index in audioTracks.indices {
            audioTracks[index].items.removeAll { deleting.contains($0.id) }
        }
        videoTracks = removingUnusedTracks(videoTracks, primaryName: "V1")
        audioTracks = removingUnusedTracks(audioTracks, primaryName: "A1")
        var operations: [GraphOp] = []
        if videoTracks != document.timeline.videoTracks {
            operations.append(.setVideoTracks(videoTracks))
        }
        if audioTracks != document.timeline.audioTracks {
            operations.append(.setAudioTracks(audioTracks))
        }
        guard !operations.isEmpty else { return }
        do {
            try perform(GraphPatch(ops: operations, label: "Delete Media", origin: .user))
            selection.removeAll()
            if let targetedVideoTrackID,
                !document.timeline.videoTracks.contains(where: { $0.id == targetedVideoTrackID })
            {
                self.targetedVideoTrackID = document.timeline.videoTracks.first?.id
            }
            notice = deleting.count == 1 ? "Media deleted." : "Selected media deleted."
        } catch {
            notice = "Locked media could not be deleted."
        }
    }

    /// Materializes source audio into explicit A tracks. This keeps every
    /// audible clip present, then selects the detached audio matching the video.
    public func separateSelectedAudio() {
        guard canSeparateSelectedAudio, let source = selectedItem else {
            notice = "Select a video clip that contains audio."
            return
        }
        if let existing = matchingAudioItem(for: source, in: document.timeline.audioTracks) {
            selection = [existing.id]
            notice = "Selected the separated audio."
            return
        }
        var result = materializedAudioTracks()
        if !document.timeline.audioTracks.isEmpty {
            result.tracks = document.timeline.audioTracks
            let audioItem = audioCopy(of: source)
            insert(audioItem, intoFirstAvailableTrack: &result.tracks, prefix: "A")
            result.sourceMap[source.id] = audioItem.id
        }
        guard !result.tracks.isEmpty else {
            notice = "This project has no source audio to separate."
            return
        }
        do {
            try perform(
                GraphPatch(
                    ops: [.setAudioTracks(result.tracks)],
                    label: "Separate Audio",
                    origin: .user
                )
            )
            if let detachedID = result.sourceMap[source.id]
                ?? matchingAudioItem(for: source, in: result.tracks)?.id
            {
                selection = [detachedID]
            }
            notice = "Audio separated onto editable audio tracks."
        } catch {
            notice = "The audio could not be separated."
        }
    }

    /// Gives the selected media a shared nest identifier. Playback stays
    /// non-destructive, while selection and delete now treat the items as a unit.
    public func nestSelection() {
        guard canNestSelection else {
            notice = "Shift-select at least two video or audio clips to nest them."
            return
        }
        let nestID = "nest-\(UUID().uuidString.lowercased())"
        if setNestID(nestID, for: selection, label: "Nest Media") {
            notice = "Nested \(selection.count) items into one editing group."
        }
    }

    public func unnestSelection() {
        let nestIDs = Set(selection.compactMap { document.item($0)?.nestID })
        guard !nestIDs.isEmpty else {
            notice = "Select nested media to separate it."
            return
        }
        let itemIDs = Set(
            (document.timeline.videoTracks + document.timeline.audioTracks)
                .flatMap(\.items)
                .filter { item in item.nestID.map(nestIDs.contains) == true }
                .map(\.id)
        )
        if setNestID(nil, for: itemIDs, label: "Unnest Media") {
            selection = itemIDs
            notice = "Nested media separated."
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

    public func targetVideoTrack(_ trackID: TrackID) {
        guard document.timeline.videoTracks.contains(where: { $0.id == trackID }) else { return }
        targetedVideoTrackID = trackID
        notice = "Targeting \(targetedVideoTrack?.name ?? "video track")."
    }

    public func addOverlayTrack() {
        var tracks = document.timeline.videoTracks
        if tracks.isEmpty {
            tracks.append(Track(id: TrackID(rawValue: "v1"), name: "V1"))
        }
        let track = Track(id: .generate(), name: "V\(tracks.count + 1)")
        tracks.append(track)
        do {
            try perform(
                GraphPatch(
                    ops: [.setVideoTracks(tracks)],
                    label: "Add Overlay Track",
                    origin: .user
                )
            )
            targetedVideoTrackID = track.id
            notice = "Added and targeted \(track.name) for overlays."
        } catch {
            notice = "The overlay track could not be added."
        }
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

    /// Selects the visible clip when the preview is manipulated directly.
    @discardableResult
    public func selectClipAtPlayheadIfNeeded() -> Bool {
        if selectedItem != nil, selectedTrackKind == .video { return true }
        guard let item = document.item(at: playhead)?.item else {
            notice = "Move the playhead over a clip before positioning it."
            return false
        }
        selection = [item.id]
        return true
    }

    /// Repositions the selected video in canvas-normalized coordinates.
    public func translateSelectedClip(by delta: NormalizedPoint) {
        guard selectClipAtPlayheadIfNeeded(), let selectedItem,
            delta.x.isFinite, delta.y.isFinite,
            abs(delta.x) > 0.0001 || abs(delta.y) > 0.0001
        else { return }
        var transform = selectedTransform
        transform.translationX = min(max(transform.translationX + delta.x, -2), 2)
        transform.translationY = min(max(transform.translationY + delta.y, -2), 2)
        if selectedItem.transform.keyframes.isEmpty {
            updateItem(selectedItem.id, label: "Position Clip") {
                $0.transform.constant = transform
            }
        } else {
            setTransformKeyframe(transform)
        }
    }

    public func resetSelectedPosition() {
        guard let selectedItem else { return }
        var transform = selectedTransform
        transform.translationX = 0
        transform.translationY = 0
        if selectedItem.transform.keyframes.isEmpty {
            updateItem(selectedItem.id, label: "Reset Clip Position") {
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

    /// Hands one or more OCR regions to the existing destructive video effect path.
    /// Regions use Clip's top-left normalized canvas coordinates.
    public func redactCurrentRegions(_ regions: [NormalizedRect]) {
        guard let item = document.item(at: playhead)?.item else {
            notice = "Move the playhead over a clip before adding a redaction."
            return
        }
        let valid = regions.filter {
            $0.width > 0 && $0.height > 0 && $0.x < 1 && $0.y < 1
                && $0.x + $0.width > 0 && $0.y + $0.height > 0
        }
        guard !valid.isEmpty else { return }
        let operations = valid.map { region in
            GraphOp.addEffect(
                item.id,
                .blur(
                    BlurEffect(
                        id: .generate(),
                        range: item.effectRange,
                        regions: [TimedRegion(time: .zero, rect: region)],
                        mode: .pixelate(size: 14),
                        isDestructiveOnExport: true
                    )
                )
            )
        }
        do {
            try perform(
                GraphPatch(ops: operations, label: "Redact Live Text", origin: .user)
            )
            notice = valid.count == 1 ? "Redaction added." : "Redactions added."
        } catch {
            notice = "The redaction could not be added."
        }
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
        guard let duration = asset.duration, duration > .zero,
            asset.kind == .video || asset.kind == .audio
        else {
            notice = "That asset has no playable duration."
            return false
        }
        let previousAsset = assets.updateValue(asset, forKey: asset.id)
        let inserted: TimelineItem
        do {
            switch asset.kind {
            case .video:
                inserted = try insertVideoAsset(asset, duration: duration)
            case .audio:
                inserted = try insertAudioAsset(asset, duration: duration)
            case .image, .document, .text:
                return false
            }
            selection = [inserted.id]
            return true
        } catch {
            if let previousAsset {
                assets[asset.id] = previousAsset
            } else {
                assets.removeValue(forKey: asset.id)
            }
            notice =
                asset.kind == .audio
                ? "The audio could not be added at the playhead."
                : "The clip could not be added to the targeted video track."
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

    private func insertVideoAsset(
        _ asset: AssetRecord,
        duration: RationalTime
    ) throws -> TimelineItem {
        var tracks = document.timeline.videoTracks
        if tracks.isEmpty {
            tracks = [Track(id: TrackID(rawValue: "v1"), name: "V1")]
        }
        let targetIndex = tracks.firstIndex { $0.id == targetedVideoTrackID } ?? 0
        guard !tracks[targetIndex].isLocked else {
            throw ModelError.trackLocked(tracks[targetIndex].id)
        }
        var item = TimelineItem(
            id: .generate(),
            assetID: asset.id,
            sourceRange: TimeRange(start: .zero, duration: duration)
        )
        var nextTargetID = targetedVideoTrackID ?? tracks.first?.id
        if targetIndex == 0 {
            item.timelineStart = tracks[0].items.map(\.timelineEnd).max() ?? .zero
            tracks[0].items.append(item)
        } else {
            item.timelineStart = min(playhead, document.duration)
            if overlaps(item, items: tracks[targetIndex].items) {
                let newTrack = Track(
                    id: TrackID.generate(),
                    name: "V\(tracks.count + 1)",
                    items: [item]
                )
                tracks.append(newTrack)
                nextTargetID = newTrack.id
            } else {
                tracks[targetIndex].items.append(item)
                tracks[targetIndex].items.sort { $0.timelineStart < $1.timelineStart }
            }
        }
        try perform(
            GraphPatch(ops: [.setVideoTracks(tracks)], label: "Add Video", origin: .user)
        )
        targetedVideoTrackID = nextTargetID
        return item
    }

    private func insertAudioAsset(
        _ asset: AssetRecord,
        duration: RationalTime
    ) throws -> TimelineItem {
        var tracks =
            document.timeline.audioTracks.isEmpty
            ? materializedAudioTracks().tracks
            : document.timeline.audioTracks
        let item = TimelineItem(
            id: .generate(),
            assetID: asset.id,
            sourceRange: TimeRange(start: .zero, duration: duration),
            timelineStart: min(playhead, document.duration)
        )
        insert(item, intoFirstAvailableTrack: &tracks, prefix: "A")
        try perform(
            GraphPatch(ops: [.setAudioTracks(tracks)], label: "Add Audio", origin: .user)
        )
        return item
    }

    private func materializedAudioTracks() -> (
        tracks: [Track],
        sourceMap: [ItemID: ItemID]
    ) {
        var tracks: [Track] = []
        var sourceMap: [ItemID: ItemID] = [:]
        let sources = document.timeline.videoTracks
            .flatMap(\.items)
            .filter { assets[$0.assetID]?.hasAudio == true }
            .sorted { left, right in
                left.timelineStart == right.timelineStart
                    ? left.id.rawValue < right.id.rawValue
                    : left.timelineStart < right.timelineStart
            }
        for source in sources {
            let audioItem = audioCopy(of: source)
            insert(audioItem, intoFirstAvailableTrack: &tracks, prefix: "A")
            sourceMap[source.id] = audioItem.id
        }
        return (tracks, sourceMap)
    }

    private func audioCopy(of source: TimelineItem) -> TimelineItem {
        TimelineItem(
            id: .generate(),
            assetID: source.assetID,
            sourceRange: source.sourceRange,
            timelineStart: source.timelineStart,
            speed: source.speed,
            isEnabled: source.isEnabled,
            audioFade: source.audioFade
        )
    }

    private func insert(
        _ item: TimelineItem,
        intoFirstAvailableTrack tracks: inout [Track],
        prefix: String
    ) {
        if let index = tracks.firstIndex(where: {
            !$0.isLocked && !overlaps(item, items: $0.items)
        }) {
            tracks[index].items.append(item)
            tracks[index].items.sort { $0.timelineStart < $1.timelineStart }
            return
        }
        tracks.append(
            Track(
                id: .generate(),
                name: "\(prefix)\(tracks.count + 1)",
                items: [item]
            )
        )
    }

    private func overlaps(_ item: TimelineItem, items: [TimelineItem]) -> Bool {
        let range = TimeRange(start: item.timelineStart, duration: item.timelineDuration)
        return items.contains { existing in
            TimeRange(start: existing.timelineStart, duration: existing.timelineDuration)
                .intersects(range)
        }
    }

    private func matchingAudioItem(
        for source: TimelineItem,
        in tracks: [Track]
    ) -> TimelineItem? {
        tracks.lazy.flatMap(\.items).first { audio in
            audio.assetID == source.assetID
                && audio.sourceRange == source.sourceRange
                && audio.timelineStart == source.timelineStart
                && audio.speed == source.speed
        }
    }

    private func removingUnusedTracks(_ tracks: [Track], primaryName: String) -> [Track] {
        tracks.filter { !$0.items.isEmpty || $0.name == primaryName || $0.isLocked }
    }

    private func nestedItemIDs(containing itemID: ItemID) -> Set<ItemID> {
        guard let nestID = document.item(itemID)?.nestID else { return [itemID] }
        return Set(
            (document.timeline.videoTracks + document.timeline.audioTracks)
                .flatMap(\.items)
                .filter { $0.nestID == nestID }
                .map(\.id)
        )
    }

    @discardableResult
    private func setNestID(
        _ nestID: String?,
        for itemIDs: Set<ItemID>,
        label: String
    ) -> Bool {
        var operations: [GraphOp] = []
        for track in document.timeline.videoTracks + document.timeline.audioTracks {
            var items = track.items
            var changed = false
            for index in items.indices where itemIDs.contains(items[index].id) {
                items[index].nestID = nestID
                changed = true
            }
            if changed { operations.append(.setTrackItems(track.id, items)) }
        }
        guard !operations.isEmpty else { return false }
        do {
            try perform(GraphPatch(ops: operations, label: label, origin: .user))
            return true
        } catch {
            notice = "Locked media could not be changed."
            return false
        }
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
