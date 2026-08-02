import AIKit
import CoreModel
import Foundation
import LibraryStore
import MediaEngine

/// Immutable App-layer state used to resolve one assistant turn.
public struct ToolExecutionContext: Sendable {
    public var document: ProjectDocument
    public var assets: [AssetID: AssetRecord]
    public var eventTracks: [AssetID: EventTrack]
    public var selectedItemIDs: Set<ItemID>
    public var playhead: RationalTime
    public var resolving: @Sendable (AssetID) async throws -> URL

    public init(
        document: ProjectDocument,
        assets: [AssetID: AssetRecord],
        eventTracks: [AssetID: EventTrack],
        selectedItemIDs: Set<ItemID> = [],
        playhead: RationalTime = .zero,
        resolving: @escaping @Sendable (AssetID) async throws -> URL
    ) {
        self.document = document
        self.assets = assets
        self.eventTracks = eventTracks
        self.selectedItemIDs = selectedItemIDs
        self.playhead = playhead
        self.resolving = resolving
    }
}

/// App-only bridge from assistant invocations to deterministic graph patches.
public struct ToolExecutor: Sendable {
    public typealias SilenceTrimmer = @Sendable (URL, Double) async throws -> TimeRange
    public typealias Transcriber = @Sendable (URL) async throws -> Transcript

    private let silenceTrimmer: SilenceTrimmer
    private let transcriber: Transcriber
    private let zoomGenerator = AutoZoomGenerator()

    public init(
        silenceTrimmer: @escaping SilenceTrimmer = { _, _ in
            throw ToolExecutorError.silenceDetectionUnavailable
        },
        transcriber: @escaping Transcriber = { url in
            try await OnDeviceTranscriber().transcribe(url)
        }
    ) {
        self.silenceTrimmer = silenceTrimmer
        self.transcriber = transcriber
    }

    public func execute(
        _ invocation: ToolInvocation,
        turnID: String,
        policy: ConfirmationPolicy,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        guard let command = CommandRegistry.command(named: invocation.name) else {
            throw ToolExecutorError.unknownTool(invocation.name)
        }
        let schema = command.schema
        if schema.kind == .confirm {
            return ToolResult(
                callID: invocation.callID,
                message: "\(invocation.name) requires your confirmation.",
                requiresConfirmation: true
            )
        }

        let patch: GraphPatch?
        let message: String
        switch invocation.name {
        case "listCommands":
            let arguments = try invocation.arguments.decode(ListCommandsArguments.self)
            let category = arguments.category.flatMap(CommandCategory.init(rawValue:))
            let commands = CommandRegistry.commands(category: category, query: arguments.query)
                .filter { $0.id.rawValue != "listCommands" && $0.id.rawValue != "runCommand" }
            patch = nil
            let names = commands.prefix(8).map { $0.id.rawValue }.joined(separator: ", ")
            let remainder = max(0, commands.count - 8)
            message =
                "\(commands.count) commands: \(names)\(remainder > 0 ? ", +\(remainder) more" : "")"
        case "runCommand":
            let arguments = try invocation.arguments.decode(RunCommandArguments.self)
            guard let target = CommandRegistry.command(id: CommandID(rawValue: arguments.id)),
                target.agentExposure == .onDemand,
                target.id.rawValue != "runCommand",
                target.id.rawValue != "listCommands"
            else {
                throw ToolExecutorError.unknownTool(arguments.id)
            }
            return try await execute(
                ToolInvocation(
                    callID: invocation.callID,
                    name: target.id.rawValue,
                    arguments: arguments.arguments ?? .object([:])
                ),
                turnID: turnID,
                policy: policy,
                context: context
            )
        case "describeTimeline":
            patch = nil
            message =
                "\(context.document.timeline.video.count) clips, \(context.document.duration.seconds.formatted()) seconds."
        case "timeline.describe":
            patch = nil
            message =
                "V1 has \(context.document.timeline.video.count) clips; audio has \(context.document.timeline.audio.count); duration \(context.document.duration.seconds.formatted())s."
        case "view.getSelection":
            patch = nil
            let ids = context.selectedItemIDs.map(\.rawValue).sorted()
            message =
                ids.isEmpty ? "Nothing is selected." : "Selected: \(ids.joined(separator: ", "))."
        case "view.getPlayhead":
            patch = nil
            let under = context.document.item(at: context.playhead)?.item.id.rawValue ?? "none"
            message = "Playhead \(context.playhead.seconds.formatted())s; clip: \(under)."
        case "audio.describe":
            patch = nil
            let audioCount = context.document.timeline.video.count { item in
                context.assets[item.assetID]?.hasAudio == true
            }
            message =
                "\(audioCount) of \(context.document.timeline.video.count) video clips contain audio; \(context.document.timeline.audio.count) audio-track clips."
        case "describeClip":
            let arguments = try invocation.arguments.decode(ItemArgument.self)
            let item = try item(arguments.itemID, in: context.document)
            patch = nil
            message =
                "Clip \(item.id.rawValue) is \(item.timelineDuration.seconds.formatted()) seconds with \(item.effects.count) effects."
        case "trimClip":
            let arguments = try invocation.arguments.decode(TrimArguments.self)
            let item = try item(arguments.itemID, in: context.document)
            let assetDuration = try duration(for: item, context: context)
            patch = assistant(
                try TimelineEditPlanner.trimClip(
                    in: context.document,
                    itemID: arguments.itemID,
                    to: range(start: arguments.start, end: arguments.end),
                    assetDuration: assetDuration
                ), turnID: turnID)
            message = "Trimmed the clip."
        case "splitClip":
            let arguments = try invocation.arguments.decode(SplitArguments.self)
            patch = assistant(
                try TimelineEditPlanner.splitClip(
                    in: context.document,
                    itemID: arguments.itemID,
                    at: RationalTime(seconds: arguments.at),
                    rightItemID: .generate()
                ), turnID: turnID)
            message = "Split the clip."
        case "reorderClips":
            let arguments = try invocation.arguments.decode(ReorderArguments.self)
            try requireItems(arguments.order, in: context.document)
            patch = GraphPatch(
                ops: arguments.order.enumerated().map { .moveItem($0.element, toIndex: $0.offset) },
                label: "Assistant: Reorder Clips", origin: .assistant(turnID: turnID))
            message = "Reordered the clips."
        case "timeline.rippleDelete":
            let arguments = try invocation.arguments.decode(ItemArgument.self)
            patch = assistant(
                try TimelineEditPlanner.rippleDelete(
                    in: context.document,
                    itemID: arguments.itemID
                ),
                turnID: turnID
            )
            message = "Ripple deleted the clip."
        case "timeline.roll":
            let arguments = try invocation.arguments.decode(PrecisionEditArguments.self)
            patch = assistant(
                try TimelineEditPlanner.rollEdit(
                    in: context.document,
                    leftItemID: arguments.itemID,
                    by: RationalTime(seconds: arguments.delta),
                    assetDurations: context.assets.compactMapValues(\.duration)
                ),
                turnID: turnID
            )
            message = "Rolled the cut by \(arguments.delta.formatted()) seconds."
        case "timeline.slip":
            let arguments = try invocation.arguments.decode(PrecisionEditArguments.self)
            let target = try item(arguments.itemID, in: context.document)
            patch = assistant(
                try TimelineEditPlanner.slipClip(
                    in: context.document,
                    itemID: arguments.itemID,
                    by: RationalTime(seconds: arguments.delta),
                    assetDuration: try duration(for: target, context: context)
                ),
                turnID: turnID
            )
            message = "Slipped the clip by \(arguments.delta.formatted()) seconds."
        case "timeline.slide":
            let arguments = try invocation.arguments.decode(PrecisionEditArguments.self)
            patch = assistant(
                try TimelineEditPlanner.slideClip(
                    in: context.document,
                    itemID: arguments.itemID,
                    by: RationalTime(seconds: arguments.delta),
                    assetDurations: context.assets.compactMapValues(\.duration)
                ),
                turnID: turnID
            )
            message = "Slid the clip by \(arguments.delta.formatted()) seconds."
        case "timeline.addMarker":
            let arguments = try invocation.arguments.decode(MarkerArguments.self)
            let marker = Marker(
                id: .generate(),
                name: arguments.name ?? "Marker",
                time: RationalTime(seconds: arguments.time ?? context.playhead.seconds)
            )
            patch = assistant(
                TimelineEditPlanner.addMarker(to: context.document, marker: marker),
                turnID: turnID
            )
            message = "Added a marker at \(marker.time.seconds.formatted()) seconds."
        case "timeline.crossDissolve":
            let arguments = try invocation.arguments.decode(TransitionArguments.self)
            patch = assistant(
                try TimelineEditPlanner.crossDissolve(
                    in: context.document,
                    leftItemID: arguments.itemID,
                    duration: RationalTime(seconds: arguments.duration)
                ),
                turnID: turnID
            )
            message = "Applied a \(arguments.duration.formatted()) second dissolve."
        case "timeline.audioFade":
            let arguments = try invocation.arguments.decode(AudioFadeArguments.self)
            patch = assistant(
                try TimelineEditPlanner.setAudioFade(
                    in: context.document,
                    itemID: arguments.itemID,
                    fadeIn: RationalTime(seconds: arguments.fadeIn),
                    fadeOut: RationalTime(seconds: arguments.fadeOut)
                ),
                turnID: turnID
            )
            message = "Applied audio fades."
        case "timeline.setTrackState":
            let arguments = try invocation.arguments.decode(TrackStateArguments.self)
            guard
                var track =
                    (context.document.timeline.videoTracks
                    + context.document.timeline.audioTracks).first(where: {
                        $0.id == arguments.trackID
                    })
            else {
                throw ToolExecutorError.invalidArguments("Track not found")
            }
            switch arguments.property {
            case "enabled": track.isEnabled = arguments.value
            case "locked": track.isLocked = arguments.value
            case "muted": track.isMuted = arguments.value
            case "solo": track.isSolo = arguments.value
            default:
                throw ToolExecutorError.invalidArguments(
                    "Track property must be enabled, locked, muted, or solo"
                )
            }
            patch = GraphPatch(
                ops: [.setTrack(track)],
                label: "Assistant: Set Track State",
                origin: .assistant(turnID: turnID)
            )
            message = "Updated \(track.name)."
        case "setSpeed":
            let arguments = try invocation.arguments.decode(SpeedArguments.self)
            _ = try item(arguments.itemID, in: context.document)
            patch = assistant(
                TimelineEditPlanner.setSpeed(of: arguments.itemID, to: arguments.speed),
                turnID: turnID)
            message = "Changed the clip speed."
        case "addZoom":
            let arguments = try invocation.arguments.decode(ZoomArguments.self)
            let target = try item(arguments.itemID, in: context.document)
            let effect = ZoomEffect(
                id: .generate(),
                range: range(start: arguments.range.start, end: arguments.range.end),
                center: NormalizedPoint(x: arguments.center.x, y: arguments.center.y),
                scale: arguments.scale,
                source: .manual
            )
            try validate(effect: .zoom(effect), for: target)
            patch = GraphPatch(
                ops: [.addEffect(target.id, .zoom(effect))], label: "Assistant: Add Zoom",
                origin: .assistant(turnID: turnID))
            message = "Added a zoom."
        case "autoZoomFromClicks":
            let arguments = try invocation.arguments.decode(AutoZoomArguments.self)
            try requireItems(arguments.itemIDs, in: context.document)
            let options = arguments.options?.value ?? AutoZoomGenerator.Options()
            var operations: [GraphOp] = []
            for itemID in arguments.itemIDs {
                let target = try item(itemID, in: context.document)
                guard let track = context.eventTracks[target.assetID] else {
                    throw ToolExecutorError.missingEventTrack(itemID)
                }
                operations.append(
                    contentsOf: zoomGenerator.zooms(for: track, item: target, options: options)
                        .map { .addEffect(itemID, .zoom($0)) })
            }
            patch = GraphPatch(
                ops: operations, label: "Assistant: Auto Zoom",
                origin: .assistant(turnID: turnID))
            message = "Added \(operations.count) click-based zooms."
        case "removeEffect":
            let arguments = try invocation.arguments.decode(RemoveEffectArguments.self)
            let target = try item(arguments.itemID, in: context.document)
            guard target.effects.contains(where: { $0.id == arguments.effectID }) else {
                throw ToolExecutorError.effectNotFound(arguments.effectID)
            }
            patch = GraphPatch(
                ops: [.removeEffect(arguments.itemID, arguments.effectID)],
                label: "Assistant: Remove Effect", origin: .assistant(turnID: turnID))
            message = "Removed the effect."
        case "setBackground":
            let arguments = try invocation.arguments.decode(BackgroundArguments.self)
            try requireItems(arguments.itemIDs, in: context.document)
            let style = try backgroundStyle(arguments.style)
            patch = GraphPatch(
                ops: try arguments.itemIDs.map { itemID in
                    let target = try item(itemID, in: context.document)
                    return .addEffect(
                        itemID,
                        .background(
                            BackgroundEffect(
                                id: .generate(),
                                range: TimeRange(
                                    start: .zero, duration: target.sourceRange.duration),
                                padding: arguments.padding,
                                cornerRadius: arguments.radius,
                                style: style
                            )))
                },
                label: "Assistant: Set Background", origin: .assistant(turnID: turnID))
            message = "Set the clip background."
        case "detectSilence":
            let arguments = try invocation.arguments.decode(SilenceArguments.self)
            let ranges = try await audibleRanges(arguments, context: context)
            patch = nil
            message = ranges.map {
                "\($0.key.rawValue): \($0.value.start.seconds.formatted())–\($0.value.end.seconds.formatted())"
            }
            .sorted().joined(separator: ", ")
        case "trimSilence":
            let arguments = try invocation.arguments.decode(SilenceArguments.self)
            let ranges = try await audibleRanges(arguments, context: context)
            var operations: [GraphOp] = []
            for itemID in arguments.itemIDs {
                guard let audible = ranges[itemID] else { continue }
                let target = try item(itemID, in: context.document)
                let planned = try TimelineEditPlanner.trimClip(
                    in: context.document, itemID: itemID, to: audible,
                    assetDuration: try duration(for: target, context: context))
                operations.append(contentsOf: planned.ops)
            }
            patch = GraphPatch(
                ops: operations, label: "Assistant: Trim Silence",
                origin: .assistant(turnID: turnID))
            message = "Trimmed the dead air."
        case "generateCaptions":
            let arguments = try invocation.arguments.decode(CaptionArguments.self)
            guard arguments.engine == "onDevice" || arguments.engine == "on-device" else {
                throw ToolExecutorError.remoteCaptioningRequiresConsent
            }
            try requireItems(arguments.itemIDs, in: context.document)
            var captions = context.document.timeline.captions.filter { existing in
                !arguments.itemIDs.contains { itemID in
                    guard let start = context.document.timelineStart(of: itemID),
                        let target = context.document.item(itemID)
                    else { return false }
                    let window = TimeRange(start: start, duration: target.timelineDuration)
                    return existing.range.clamped(to: window).duration > .zero
                }
            }
            for itemID in arguments.itemIDs {
                let target = try item(itemID, in: context.document)
                guard context.assets[target.assetID]?.hasAudio == true else {
                    throw ToolExecutorError.clipHasNoAudio(itemID)
                }
                let transcript = try await transcriber(try await context.resolving(target.assetID))
                let timelineStart = context.document.timelineStart(of: itemID) ?? .zero
                for (index, segment) in transcript.segments.enumerated() {
                    let sourceStart = RationalTime(seconds: segment.start)
                    let sourceEnd = sourceStart + RationalTime(seconds: segment.duration)
                    let clipped = TimeRange(start: sourceStart, duration: sourceEnd - sourceStart)
                        .clamped(to: target.sourceRange)
                    guard clipped.duration > .zero else { continue }
                    let localStart = (clipped.start - target.sourceRange.start).scaled(
                        by: 1 / target.speed)
                    let localDuration = clipped.duration.scaled(by: 1 / target.speed)
                    captions.append(
                        CaptionSegment(
                            id: "assistant-\(turnID)-\(itemID.rawValue)-\(index)",
                            range: TimeRange(
                                start: timelineStart + localStart, duration: localDuration),
                            text: segment.text
                        ))
                }
            }
            patch = GraphPatch(
                ops: [.setCaptions(captions.sorted { $0.range.start < $1.range.start })],
                label: "Assistant: Generate Captions", origin: .assistant(turnID: turnID))
            message = "Generated captions on device."
        default:
            throw ToolExecutorError.unknownTool(invocation.name)
        }

        return ToolResult(
            callID: invocation.callID,
            message: message,
            patch: patch,
            requiresConfirmation: policy.requiresConfirmation(
                for: schema.kind,
                isDestructive: command.isDestructive
            )
        )
    }

    private func audibleRanges(
        _ arguments: SilenceArguments,
        context: ToolExecutionContext
    ) async throws -> [ItemID: TimeRange] {
        try requireItems(arguments.itemIDs, in: context.document)
        var ranges: [ItemID: TimeRange] = [:]
        for itemID in arguments.itemIDs {
            let target = try item(itemID, in: context.document)
            guard context.assets[target.assetID]?.hasAudio == true else {
                throw ToolExecutorError.clipHasNoAudio(itemID)
            }
            ranges[itemID] = try await silenceTrimmer(
                context.resolving(target.assetID), arguments.thresholdDB)
        }
        return ranges
    }
}

/// User-actionable failures while resolving a tool call.
public enum ToolExecutorError: Error, Sendable, Equatable, LocalizedError {
    case unknownTool(String)
    case itemNotFound(ItemID)
    case effectNotFound(EffectID)
    case missingEventTrack(ItemID)
    case missingAssetDuration(AssetID)
    case invalidArguments(String)
    case silenceDetectionUnavailable
    case clipHasNoAudio(ItemID)
    case remoteCaptioningRequiresConsent

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)."
        case .itemNotFound(let id): return "Clip \(id.rawValue) is no longer on the timeline."
        case .effectNotFound(let id): return "Effect \(id.rawValue) no longer exists."
        case .missingEventTrack: return "This clip has no aligned click track."
        case .missingAssetDuration: return "The source duration is unavailable."
        case .invalidArguments(let reason): return "The tool arguments are invalid: \(reason)"
        case .silenceDetectionUnavailable: return "Silence detection is unavailable."
        case .clipHasNoAudio: return "This clip has no audio."
        case .remoteCaptioningRequiresConsent: return "Remote captioning requires explicit consent."
        }
    }
}

private struct ItemArgument: Codable { var itemID: ItemID }
private struct TrimArguments: Codable {
    var itemID: ItemID
    var start: Double
    var end: Double
}
private struct SplitArguments: Codable {
    var itemID: ItemID
    var at: Double
}
private struct ReorderArguments: Codable { var order: [ItemID] }
private struct PrecisionEditArguments: Codable {
    var itemID: ItemID
    var delta: Double
}
private struct MarkerArguments: Codable {
    var time: Double?
    var name: String?
}
private struct TransitionArguments: Codable {
    var itemID: ItemID
    var duration: Double
}
private struct AudioFadeArguments: Codable {
    var itemID: ItemID
    var fadeIn: Double
    var fadeOut: Double
}
private struct TrackStateArguments: Codable {
    var trackID: TrackID
    var property: String
    var value: Bool
}
private struct SpeedArguments: Codable {
    var itemID: ItemID
    var speed: Double
}
private struct ZoomArguments: Codable {
    struct RangeValue: Codable {
        var start: Double
        var end: Double
    }
    struct PointValue: Codable {
        var x: Double
        var y: Double
    }
    var itemID: ItemID
    var range: RangeValue
    var center: PointValue
    var scale: Double
}
private struct AutoZoomArguments: Codable {
    struct OptionsValue: Codable {
        var clusterWindow: Double?
        var leadIn: Double?
        var holdOut: Double?
        var scale: Double?
        var minGap: Double?
        var maxPerMinute: Int?

        var value: AutoZoomGenerator.Options {
            AutoZoomGenerator.Options(
                clusterWindow: clusterWindow ?? 2.5,
                leadIn: leadIn ?? 0.35,
                holdOut: holdOut ?? 1.7,
                scale: scale ?? 1.85,
                minGap: minGap ?? 0.6,
                maxPerMinute: maxPerMinute ?? 12
            )
        }
    }
    var itemIDs: [ItemID]
    var options: OptionsValue?
}
private struct RemoveEffectArguments: Codable {
    var itemID: ItemID
    var effectID: EffectID
}
private struct BackgroundArguments: Codable {
    var itemIDs: [ItemID]
    var padding: Double
    var radius: Double
    var style: JSONValue
}
private struct SilenceArguments: Codable {
    var itemIDs: [ItemID]
    var thresholdDB: Double
}
private struct CaptionArguments: Codable {
    var itemIDs: [ItemID]
    var engine: String
}
private struct ListCommandsArguments: Codable {
    var category: String?
    var query: String?
}
private struct RunCommandArguments: Codable {
    var id: String
    var arguments: JSONValue?
}

private func assistant(_ patch: GraphPatch, turnID: String) -> GraphPatch {
    GraphPatch(
        ops: patch.ops, label: "Assistant: \(patch.label)", origin: .assistant(turnID: turnID))
}

private func item(_ id: ItemID, in document: ProjectDocument) throws -> TimelineItem {
    guard let value = document.item(id) else { throw ToolExecutorError.itemNotFound(id) }
    return value
}

private func requireItems(_ ids: [ItemID], in document: ProjectDocument) throws {
    for id in ids { _ = try item(id, in: document) }
}

private func duration(for item: TimelineItem, context: ToolExecutionContext) throws -> RationalTime
{
    guard let value = context.assets[item.assetID]?.duration else {
        throw ToolExecutorError.missingAssetDuration(item.assetID)
    }
    return value
}

private func range(start: Double, end: Double) -> TimeRange {
    TimeRange(start: RationalTime(seconds: start), duration: RationalTime(seconds: end - start))
}

private func validate(effect: Effect, for item: TimelineItem) throws {
    guard effect.range.start >= .zero, effect.range.end <= item.sourceRange.duration,
        effect.range.duration > .zero
    else { throw ToolExecutorError.invalidArguments("Effect range is outside the clip") }
}

private func backgroundStyle(_ value: JSONValue) throws -> BackgroundStyle {
    if case .object(let object) = value {
        if let asset = object["assetID"]?.text { return .image(AssetID(rawValue: asset)) }
        let color = object["color"] ?? value
        if case .object(let channels) = color,
            let r = channels["r"]?.number,
            let g = channels["g"]?.number,
            let b = channels["b"]?.number
        {
            return .solid(RGBA(r: r, g: g, b: b, a: channels["a"]?.number ?? 1))
        }
    }
    throw ToolExecutorError.invalidArguments("Background style needs RGBA channels or assetID")
}

extension JSONValue {
    fileprivate var text: String? { if case .string(let value) = self { value } else { nil } }
    fileprivate var number: Double? { if case .number(let value) = self { value } else { nil } }
}
