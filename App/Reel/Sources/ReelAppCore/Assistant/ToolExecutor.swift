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
    public var resolving: @Sendable (AssetID) async throws -> URL

    public init(
        document: ProjectDocument,
        assets: [AssetID: AssetRecord],
        eventTracks: [AssetID: EventTrack],
        resolving: @escaping @Sendable (AssetID) async throws -> URL
    ) {
        self.document = document
        self.assets = assets
        self.eventTracks = eventTracks
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
        guard let schema = ToolCatalog.schema(named: invocation.name) else {
            throw ToolExecutorError.unknownTool(invocation.name)
        }
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
        case "describeTimeline":
            patch = nil
            message =
                "\(context.document.timeline.video.count) clips, \(context.document.duration.seconds.formatted()) seconds."
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
            requiresConfirmation: policy.requiresConfirmation(for: schema.kind)
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
