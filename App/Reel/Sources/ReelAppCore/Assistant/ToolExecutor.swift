import AIKit
import ConvertKit
import CoreModel
import Foundation
import LibraryStore
import MediaEngine
import SearchEngine

/// Immutable App-layer state used to resolve one assistant turn.
public struct ToolExecutionContext: Sendable {
    public typealias LibrarySearcher = @Sendable (SearchQuery) async throws -> SearchResponse
    public typealias AssetSearcher = @Sendable (AssetID, String) async throws -> [SearchMoment]
    public typealias TextReader = @Sendable (AssetID, RationalTime) async throws -> [OCRSpan]
    public typealias SimilarSearcher = @Sendable (AssetID, Int) async throws -> [SearchHit]
    public typealias BatchConverter =
        @Sendable ([BatchConversionJob]) async throws -> [BatchItemOutcome]

    public var document: ProjectDocument
    public var assets: [AssetID: AssetRecord]
    public var eventTracks: [AssetID: EventTrack]
    public var selectedItemIDs: Set<ItemID>
    public var playhead: RationalTime
    public var resolving: @Sendable (AssetID) async throws -> URL
    public var searching: LibrarySearcher
    public var searchingWithin: AssetSearcher
    public var readingText: TextReader
    public var searchingSimilar: SimilarSearcher
    public var conversionDestination: URL?
    public var converting: BatchConverter

    public init(
        document: ProjectDocument,
        assets: [AssetID: AssetRecord],
        eventTracks: [AssetID: EventTrack],
        selectedItemIDs: Set<ItemID> = [],
        playhead: RationalTime = .zero,
        resolving: @escaping @Sendable (AssetID) async throws -> URL,
        searching: @escaping LibrarySearcher = { _ in
            throw ToolExecutorError.searchUnavailable
        },
        searchingWithin: @escaping AssetSearcher = { _, _ in
            throw ToolExecutorError.searchUnavailable
        },
        readingText: @escaping TextReader = { _, _ in
            throw ToolExecutorError.searchUnavailable
        },
        searchingSimilar: @escaping SimilarSearcher = { _, _ in
            throw ToolExecutorError.searchUnavailable
        },
        conversionDestination: URL? = nil,
        converting: @escaping BatchConverter = { _ in
            throw ToolExecutorError.conversionUnavailable
        }
    ) {
        self.document = document
        self.assets = assets
        self.eventTracks = eventTracks
        self.selectedItemIDs = selectedItemIDs
        self.playhead = playhead
        self.resolving = resolving
        self.searching = searching
        self.searchingWithin = searchingWithin
        self.readingText = readingText
        self.searchingSimilar = searchingSimilar
        self.conversionDestination = conversionDestination
        self.converting = converting
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
        context: ToolExecutionContext,
        confirmed: Bool = false
    ) async throws -> ToolResult {
        guard let command = CommandRegistry.command(named: invocation.name) else {
            throw ToolExecutorError.unknownTool(invocation.name)
        }
        let schema = command.schema
        if schema.kind == .confirm && !confirmed {
            let detail =
                invocation.name == "convert.run"
                ? try conversionConfirmation(
                    invocation.arguments.decode(ConvertArguments.self), context: context)
                : "\(invocation.name) requires your confirmation."
            return ToolResult(
                callID: invocation.callID,
                message: detail,
                requiresConfirmation: true
            )
        }

        let patch: GraphPatch?
        let message: String
        switch invocation.name {
        case "search.library":
            let arguments = try invocation.arguments.decode(SearchLibraryArguments.self)
            let filters = try searchFilters(arguments)
            let mode = try searchMode(arguments.mode)
            let response = try await context.searching(
                SearchQuery(
                    text: arguments.text,
                    filters: filters,
                    mode: mode,
                    limit: arguments.limit ?? 20
                )
            )
            patch = nil
            message =
                searchResults(response.hits, context: context)
                + (response.isComplete
                    ? "\nIndex status: complete." : "\nIndex status: still indexing.")
        case "search.withinAsset":
            let arguments = try invocation.arguments.decode(SearchWithinArguments.self)
            let assetID = AssetID(rawValue: arguments.assetID)
            let moments = try await context.searchingWithin(assetID, arguments.text)
            patch = nil
            message = momentResults(moments, assetID: assetID, context: context)
        case "search.textAt":
            let arguments = try invocation.arguments.decode(SearchTextAtArguments.self)
            let assetID = AssetID(rawValue: arguments.assetID)
            let spans = try await context.readingText(
                assetID,
                RationalTime(seconds: arguments.time)
            )
            patch = nil
            message = textResults(spans, assetID: assetID, time: arguments.time)
        case "search.similar":
            let arguments = try invocation.arguments.decode(SearchSimilarArguments.self)
            let hits = try await context.searchingSimilar(
                AssetID(rawValue: arguments.assetID),
                arguments.limit ?? 10
            )
            patch = nil
            message = searchResults(hits, context: context)
        case "convert.listTargets":
            let arguments = try invocation.arguments.decode(ConvertAssetArguments.self)
            let records = try conversionAssets(arguments.assetIDs, context: context)
            let planner = ConversionPlanner()
            let sets = try records.map { asset -> Set<TargetFormat> in
                guard let source = FormatID(asset: asset) else {
                    throw ToolExecutorError.invalidArguments(
                        "The source format for \(asset.displayName) could not be identified"
                    )
                }
                return Set(
                    TargetFormat.allCases.filter { target in
                        target.formatID != source
                            && planner.plan(from: source, to: target.formatID) != nil
                    }
                )
            }
            let common = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
            let targets = TargetFormat.allCases.filter(common.contains)
            patch = nil
            message =
                targets.isEmpty
                ? "No common conversion target is available for these assets."
                : "Common targets for \(records.count) asset\(records.count == 1 ? "" : "s"): "
                    + targets.map { "\($0.rawValue) (\($0.displayName))" }
                    .joined(separator: ", ")
        case "convert.plan":
            let arguments = try invocation.arguments.decode(ConvertArguments.self)
            patch = nil
            message = try conversionPlanDescription(arguments, context: context)
        case "convert.presets":
            patch = nil
            message = ConversionPreset.builtIns.map { preset in
                let tradeoff = preset.options.removesMetadata ? "metadata removed" : "metadata kept"
                return "\(preset.id): \(preset.name) → \(preset.target.rawValue) · \(tradeoff)"
            }.joined(separator: "\n")
        case "convert.run":
            let arguments = try invocation.arguments.decode(ConvertArguments.self)
            let prepared = try await prepareConversionJobs(arguments, context: context)
            let outcomes =
                prepared.jobs.isEmpty
                ? [] : try await context.converting(prepared.jobs)
            guard outcomes.count == prepared.jobs.count else {
                throw ToolExecutorError.conversionFailed(
                    "The converter returned \(outcomes.count) results for \(prepared.jobs.count) files"
                )
            }
            let succeeded = outcomes.compactMap { outcome -> URL? in
                if case .succeeded(let url) = outcome { return url }
                return nil
            }
            let failures = outcomes.compactMap { outcome -> String? in
                switch outcome {
                case .failed(let reason): return reason
                case .cancelled: return "cancelled"
                case .succeeded: return nil
                }
            }
            patch = nil
            message =
                "Converted \(succeeded.count) of \(prepared.requested) files"
                + (prepared.skipped == 0 ? "" : "; skipped \(prepared.skipped) existing files")
                + (failures.isEmpty ? "." : "; failures: \(failures.joined(separator: "; ")).")
                + (succeeded.isEmpty
                    ? "" : "\nOutputs:\n" + succeeded.map(\.path).joined(separator: "\n"))
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
                context: context,
                confirmed: confirmed
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
        case "setKeyframe":
            let arguments = try invocation.arguments.decode(KeyframeArguments.self)
            let easing = Easing(rawValue: arguments.easing ?? "smoothstep") ?? .smoothstep
            let planned: GraphPatch
            switch arguments.property {
            case "opacity":
                guard let itemID = arguments.itemID, let value = arguments.value.number else {
                    throw ToolExecutorError.invalidArguments("Opacity needs itemID and a number")
                }
                planned = try TimelineEditPlanner.setOpacityKeyframe(
                    in: context.document,
                    itemID: itemID,
                    at: RationalTime(seconds: arguments.time),
                    value: value,
                    easing: easing
                )
            case "gain":
                guard let trackID = arguments.trackID, let value = arguments.value.number else {
                    throw ToolExecutorError.invalidArguments("Gain needs trackID and decibels")
                }
                planned = try TimelineEditPlanner.setGainKeyframe(
                    in: context.document,
                    trackID: trackID,
                    at: RationalTime(seconds: arguments.time),
                    decibels: value,
                    easing: easing
                )
            case "blurRadius":
                guard let itemID = arguments.itemID,
                    let effectID = arguments.effectID,
                    let value = arguments.value.number
                else {
                    throw ToolExecutorError.invalidArguments(
                        "Blur radius needs itemID, effectID, and a number"
                    )
                }
                planned = try TimelineEditPlanner.setBlurIntensityKeyframe(
                    in: context.document,
                    itemID: itemID,
                    effectID: effectID,
                    at: RationalTime(seconds: arguments.time),
                    value: value,
                    easing: easing
                )
            case "zoomScale":
                guard let itemID = arguments.itemID,
                    let effectID = arguments.effectID,
                    let value = arguments.value.number
                else {
                    throw ToolExecutorError.invalidArguments(
                        "Zoom scale needs itemID, effectID, and a number"
                    )
                }
                planned = try TimelineEditPlanner.setZoomScaleKeyframe(
                    in: context.document,
                    itemID: itemID,
                    effectID: effectID,
                    at: RationalTime(seconds: arguments.time),
                    value: value,
                    easing: easing
                )
            case "transform":
                guard let itemID = arguments.itemID,
                    case .object(let fields) = arguments.value
                else {
                    throw ToolExecutorError.invalidArguments(
                        "Transform needs itemID and transform fields"
                    )
                }
                planned = try TimelineEditPlanner.setTransformKeyframe(
                    in: context.document,
                    itemID: itemID,
                    at: RationalTime(seconds: arguments.time),
                    value: try transform(from: fields),
                    easing: easing
                )
            default:
                throw ToolExecutorError.invalidArguments(
                    "Property must be opacity, gain, transform, blurRadius, or zoomScale"
                )
            }
            patch = assistant(planned, turnID: turnID)
            message = "Set the \(arguments.property) keyframe."
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
            requiresConfirmation: !confirmed
                && policy.requiresConfirmation(
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
    case searchUnavailable
    case conversionUnavailable
    case conversionFailed(String)

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
        case .searchUnavailable: return "Library search is unavailable."
        case .conversionUnavailable: return "Conversion is unavailable in this workspace."
        case .conversionFailed(let reason): return "Conversion failed: \(reason)."
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
private struct KeyframeArguments: Codable {
    var property: String
    var time: Double
    var value: JSONValue
    var itemID: ItemID?
    var trackID: TrackID?
    var effectID: EffectID?
    var easing: String?
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
private struct SearchLibraryArguments: Codable {
    var text: String
    var kind: String?
    var after: String?
    var before: String?
    var folder: String?
    var minimumDuration: Double?
    var maximumDuration: Double?
    var hasAudio: Bool?
    var mode: String?
    var limit: Int?
}
private struct SearchWithinArguments: Codable {
    var assetID: String
    var text: String
}
private struct SearchTextAtArguments: Codable {
    var assetID: String
    var time: Double
}
private struct SearchSimilarArguments: Codable {
    var assetID: String
    var limit: Int?
}
private struct ConvertAssetArguments: Codable {
    var assetIDs: [String]
}
private struct ConvertArguments: Codable {
    var assetIDs: [String]
    var target: String
    var preset: String?
    var quality: Double?
    var longestSide: Int?
    var maximumBytes: Int?
    var stripMetadata: Bool?
    var destination: String?
    var filenameTemplate: String?
    var conflictPolicy: String?
}

private struct PreparedConversionJobs {
    var jobs: [BatchConversionJob]
    var skipped: Int
    var requested: Int
}

private func conversionAssets(
    _ rawIDs: [String],
    context: ToolExecutionContext
) throws -> [AssetRecord] {
    guard !rawIDs.isEmpty else {
        throw ToolExecutorError.invalidArguments("At least one assetID is required")
    }
    var seen: Set<AssetID> = []
    return try rawIDs.compactMap { rawID in
        let id = AssetID(rawValue: rawID)
        guard seen.insert(id).inserted else { return nil }
        guard let asset = context.assets[id] else {
            throw ToolExecutorError.invalidArguments("Asset \(rawID) is not in the library")
        }
        guard !asset.isMissing else {
            throw ToolExecutorError.invalidArguments("Asset \(rawID) is offline")
        }
        return asset
    }
}

private func conversionTarget(_ rawValue: String) throws -> TargetFormat {
    let normalized = rawValue.lowercased().filter(\.isLetter)
    if let target = TargetFormat.allCases.first(where: { candidate in
        let values = [candidate.rawValue, candidate.displayName, candidate.fileExtension]
        return values.contains { $0.lowercased().filter(\.isLetter) == normalized }
    }) {
        return target
    }
    let aliases: [String: TargetFormat] = [
        "jpg": .jpeg, "jpeg": .jpeg, "weboptimizedjpeg": .jpeg,
        "gif": .animatedGIF, "animatedgif": .animatedGIF,
        "mp4": .mp4H264, "h264": .mp4H264, "hevc": .mp4HEVC,
        "webm": .webMVP9, "mkv": .matroska, "txt": .plainText,
    ]
    guard let target = aliases[normalized] else {
        throw ToolExecutorError.invalidArguments("Unknown conversion target \(rawValue)")
    }
    return target
}

private func conversionOptions(
    _ arguments: ConvertArguments,
    target: TargetFormat
) throws -> ConversionOptions {
    var options: ConversionOptions
    if let requestedPreset = arguments.preset {
        let normalized = requestedPreset.lowercased()
        guard
            let preset = ConversionPreset.builtIns.first(where: {
                $0.id.lowercased() == normalized || $0.name.lowercased() == normalized
            })
        else {
            throw ToolExecutorError.invalidArguments("Unknown preset \(requestedPreset)")
        }
        guard preset.target == target else {
            throw ToolExecutorError.invalidArguments(
                "Preset \(preset.name) targets \(preset.target.rawValue), not \(target.rawValue)"
            )
        }
        options = preset.options
    } else {
        options = ConversionOptions()
    }

    if let quality = arguments.quality {
        let normalized = quality > 1 ? quality / 100 : quality
        guard (0...1).contains(normalized) else {
            throw ToolExecutorError.invalidArguments("Quality must be between 0 and 1 or 0 and 100")
        }
        if target.isImageTarget {
            var image = options.image ?? ImageConversionOptions()
            image.quality = normalized
            options.image = image
        } else {
            var video = options.video ?? VideoConversionOptions()
            video.quality = normalized
            options.video = video
        }
    }
    if let longestSide = arguments.longestSide {
        guard target.isImageTarget, longestSide > 0 else {
            throw ToolExecutorError.invalidArguments(
                "longestSide requires a positive value and an image target"
            )
        }
        var image = options.image ?? ImageConversionOptions()
        image.resize = .longestSide(longestSide)
        options.image = image
    }
    if let maximumBytes = arguments.maximumBytes {
        guard maximumBytes > 0 else {
            throw ToolExecutorError.invalidArguments("maximumBytes must be positive")
        }
        guard target.supportsHardSizeLimit else {
            throw ToolExecutorError.invalidArguments(
                "A hard maximumBytes limit is currently supported for ImageIO images and GIF"
            )
        }
        if target.isImageTarget {
            var image = options.image ?? ImageConversionOptions()
            image.maximumFileSize = maximumBytes
            options.image = image
        } else {
            var video = options.video ?? VideoConversionOptions()
            video.maximumFileSize = maximumBytes
            options.video = video
        }
    }
    if arguments.stripMetadata == true { options.stripAllMetadata = true }
    if let rawPolicy = arguments.conflictPolicy {
        guard let conflictPolicy = ConversionConflictPolicy(rawValue: rawPolicy.lowercased()) else {
            throw ToolExecutorError.invalidArguments(
                "conflictPolicy must be rename, overwrite, or skip"
            )
        }
        options.conflictPolicy = conflictPolicy
    }
    return options
}

private func conversionPlanDescription(
    _ arguments: ConvertArguments,
    context: ToolExecutionContext
) throws -> String {
    let target = try conversionTarget(arguments.target)
    let options = try conversionOptions(arguments, target: target)
    let assets = try conversionAssets(arguments.assetIDs, context: context)
    let planner = ConversionPlanner()
    let rows = try assets.map { asset in
        let plan = try conversionPlan(
            asset: asset,
            target: target,
            options: options,
            planner: planner
        )
        let route = plan.steps.map(\.backend.rawValue).joined(separator: " → ")
        let warnings =
            plan.warnings.isEmpty
            ? "none" : plan.warnings.joined(separator: " ")
        return "\(asset.id.rawValue) (\(asset.displayName)): \(target.displayName) · "
            + "\(plan.isLossless ? "lossless" : "lossy") · "
            + "\(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s") via \(route) · "
            + "warnings: \(warnings)"
    }
    var constraints: [String] = []
    if let quality = arguments.quality { constraints.append("quality \(quality.formatted())") }
    if let longestSide = arguments.longestSide {
        constraints.append("longest side \(longestSide) px")
    }
    if let maximumBytes = arguments.maximumBytes {
        constraints.append("hard maximum \(maximumBytes) bytes")
    }
    if arguments.stripMetadata == true { constraints.append("metadata removed") }
    let constraintLine =
        constraints.isEmpty
        ? "" : "\nConstraints: " + constraints.joined(separator: ", ") + "."
    return "Conversion plan for \(assets.count) asset\(assets.count == 1 ? "" : "s"):\n"
        + rows.joined(separator: "\n") + constraintLine
}

private func conversionConfirmation(
    _ arguments: ConvertArguments,
    context: ToolExecutionContext
) throws -> String {
    let destination =
        arguments.destination
        ?? context.conversionDestination?.path
        ?? "the configured export folder"
    return try conversionPlanDescription(arguments, context: context)
        + "\nConfirm writing \(Set(arguments.assetIDs).count) converted file"
        + "\(Set(arguments.assetIDs).count == 1 ? "" : "s") to \(destination)."
}

private func conversionPlan(
    asset: AssetRecord,
    target: TargetFormat,
    options: ConversionOptions,
    planner: ConversionPlanner
) throws -> ConversionPlan {
    guard let source = FormatID(asset: asset) else {
        throw ToolExecutorError.invalidArguments(
            "The source format for \(asset.displayName) could not be identified"
        )
    }
    guard source != target.formatID else {
        throw ToolExecutorError.invalidArguments(
            "\(asset.displayName) is already \(target.displayName)"
        )
    }
    guard let plan = planner.plan(from: source, to: target.formatID, options: options) else {
        throw ToolExecutorError.invalidArguments(
            "\(asset.displayName) cannot be converted to \(target.displayName) with these options"
        )
    }
    return plan
}

private func prepareConversionJobs(
    _ arguments: ConvertArguments,
    context: ToolExecutionContext
) async throws -> PreparedConversionJobs {
    let assets = try conversionAssets(arguments.assetIDs, context: context)
    let target = try conversionTarget(arguments.target)
    let options = try conversionOptions(arguments, target: target)
    let destination: URL
    if let rawDestination = arguments.destination {
        guard rawDestination.hasPrefix("/") else {
            throw ToolExecutorError.invalidArguments("destination must be an absolute folder path")
        }
        destination = URL(fileURLWithPath: rawDestination, isDirectory: true).standardizedFileURL
    } else if let configured = context.conversionDestination {
        destination = configured.standardizedFileURL
    } else {
        throw ToolExecutorError.invalidArguments("No conversion destination is configured")
    }
    let planner = ConversionPlanner()
    var jobs: [BatchConversionJob] = []
    var reserved: Set<URL> = []
    var skipped = 0
    for (offset, asset) in assets.enumerated() {
        let plan = try conversionPlan(
            asset: asset,
            target: target,
            options: options,
            planner: planner
        )
        let stem = (asset.displayName as NSString).deletingPathExtension
        let filename = try conversionFilename(
            template: arguments.filenameTemplate ?? "{name}",
            name: stem,
            target: target,
            index: offset + 1
        )
        let proposed = destination.appendingPathComponent(filename)
            .appendingPathExtension(target.fileExtension)
        guard
            let output = try resolvedAgentOutput(
                proposed,
                policy: options.conflictPolicy,
                reserved: &reserved
            )
        else {
            skipped += 1
            continue
        }
        jobs.append(
            BatchConversionJob(
                plan: plan,
                input: try await context.resolving(asset.id),
                output: output
            )
        )
    }
    return PreparedConversionJobs(jobs: jobs, skipped: skipped, requested: assets.count)
}

private func conversionFilename(
    template: String,
    name: String,
    target: TargetFormat,
    index: Int
) throws -> String {
    let sanitizedName = name.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    var filename =
        template
        .replacingOccurrences(of: "{name}", with: sanitizedName)
        .replacingOccurrences(of: "{target}", with: target.fileExtension)
        .replacingOccurrences(of: "{index}", with: String(index))
    filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !filename.isEmpty, !filename.contains("/"), !filename.contains("{"),
        !filename.contains("}")
    else {
        throw ToolExecutorError.invalidArguments(
            "filenameTemplate may use only {name}, {target}, and {index}"
        )
    }
    return filename
}

private func resolvedAgentOutput(
    _ proposed: URL,
    policy: ConversionConflictPolicy,
    reserved: inout Set<URL>
) throws -> URL? {
    switch policy {
    case .overwrite:
        guard reserved.insert(proposed).inserted else {
            throw ToolExecutorError.invalidArguments(
                "Two files resolve to \(proposed.lastPathComponent)")
        }
        return proposed
    case .skip:
        guard !FileManager.default.fileExists(atPath: proposed.path),
            reserved.insert(proposed).inserted
        else { return nil }
        return proposed
    case .rename:
        if !FileManager.default.fileExists(atPath: proposed.path),
            reserved.insert(proposed).inserted
        {
            return proposed
        }
        let stem = proposed.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let candidate = proposed.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-\(suffix)")
                .appendingPathExtension(proposed.pathExtension)
            if !FileManager.default.fileExists(atPath: candidate.path),
                reserved.insert(candidate).inserted
            {
                return candidate
            }
            suffix += 1
        }
    }
}

extension TargetFormat {
    fileprivate var isImageTarget: Bool {
        switch self {
        case .png, .jpeg, .heic, .tiff, .webP: true
        default: false
        }
    }

    fileprivate var supportsHardSizeLimit: Bool {
        switch self {
        case .png, .jpeg, .heic, .tiff, .animatedGIF: true
        default: false
        }
    }
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

private func transform(from fields: [String: JSONValue]) throws -> Transform2D {
    guard let translationX = fields["translationX"]?.number,
        let translationY = fields["translationY"]?.number,
        let scaleX = fields["scaleX"]?.number,
        let scaleY = fields["scaleY"]?.number,
        let rotation = fields["rotationDegrees"]?.number
    else {
        throw ToolExecutorError.invalidArguments("Transform is missing numeric fields")
    }
    return Transform2D(
        translationX: translationX,
        translationY: translationY,
        scaleX: scaleX,
        scaleY: scaleY,
        rotationDegrees: rotation
    )
}

extension JSONValue {
    fileprivate var text: String? { if case .string(let value) = self { value } else { nil } }
    fileprivate var number: Double? { if case .number(let value) = self { value } else { nil } }
}

private func searchFilters(_ arguments: SearchLibraryArguments) throws -> SearchFilters {
    let kind: AssetKind?
    if let rawKind = arguments.kind {
        guard let value = AssetKind(rawValue: rawKind.lowercased()) else {
            throw ToolExecutorError.invalidArguments("Unknown asset kind \(rawKind)")
        }
        kind = value
    } else {
        kind = nil
    }
    return SearchFilters(
        kind: kind,
        after: try arguments.after.map { try searchDate($0, endOfDay: false) },
        before: try arguments.before.map { try searchDate($0, endOfDay: true) },
        folder: arguments.folder,
        minimumDuration: arguments.minimumDuration.map(RationalTime.init(seconds:)),
        maximumDuration: arguments.maximumDuration.map(RationalTime.init(seconds:)),
        hasAudio: arguments.hasAudio
    )
}

private func searchMode(_ value: String?) throws -> SearchMode {
    guard let value else { return .auto }
    guard let mode = SearchMode(rawValue: value.lowercased()) else {
        throw ToolExecutorError.invalidArguments("Search mode must be auto, keyword, or semantic")
    }
    return mode
}

private func searchDate(_ value: String, endOfDay: Bool) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else {
        throw ToolExecutorError.invalidArguments("Dates must use YYYY-MM-DD")
    }
    return endOfDay ? date.addingTimeInterval(86_400 - 0.001) : date
}

private func searchResults(_ hits: [SearchHit], context: ToolExecutionContext) -> String {
    guard !hits.isEmpty else { return "No matching assets." }
    let rows = hits.prefix(12).enumerated().map { index, hit in
        let itemIDs = timelineItemIDs(for: hit.assetID, context: context)
        let score = String(format: "%.4f", hit.score)
        let moment =
            hit.moments.first.map {
                " sourceAt=\(searchSeconds($0.start))s source=\($0.source.rawValue) timelineTargets=\(timelineTargets(for: hit.assetID, sourceTime: $0.start, context: context))"
            } ?? ""
        return
            "\(index + 1). assetID=\(hit.assetID.rawValue) itemIDs=\(itemIDs) score=\(score)\(moment) text=\(quoted(hit.snippet))"
    }
    let suffix = hits.count == 1 ? "" : "s"
    return "\(hits.count) matching asset\(suffix):\n" + rows.joined(separator: "\n")
}

private func momentResults(
    _ moments: [SearchMoment],
    assetID: AssetID,
    context: ToolExecutionContext
) -> String {
    guard !moments.isEmpty else { return "No matching moments in assetID=\(assetID.rawValue)." }
    let itemIDs = timelineItemIDs(for: assetID, context: context)
    let rows = moments.prefix(20).enumerated().map { index, moment in
        let end = moment.end.map { " end=\(searchSeconds($0))s" } ?? ""
        let targets = timelineTargets(for: assetID, sourceTime: moment.start, context: context)
        return
            "\(index + 1). sourceAt=\(searchSeconds(moment.start))s\(end) timelineTargets=\(targets) source=\(moment.source.rawValue) text=\(quoted(moment.snippet))"
    }
    return "\(moments.count) moments for assetID=\(assetID.rawValue) itemIDs=\(itemIDs):\n"
        + rows.joined(separator: "\n")
}

private func textResults(_ spans: [OCRSpan], assetID: AssetID, time: Double) -> String {
    let formattedTime = String(format: "%.3f", time)
    guard !spans.isEmpty else {
        return "No OCR text near source time \(formattedTime)s in assetID=\(assetID.rawValue)."
    }
    let rows = spans.prefix(40).enumerated().map { index, span in
        let box = span.boundingBox
        return
            "\(index + 1). text=\(quoted(span.text)) box=(x:\(box.x), y:\(box.y), width:\(box.width), height:\(box.height))"
    }
    return "OCR at source time \(formattedTime)s in assetID=\(assetID.rawValue):\n"
        + rows.joined(separator: "\n")
}

private func timelineItemIDs(for assetID: AssetID, context: ToolExecutionContext) -> String {
    let ids = context.document.timeline.videoTracks.flatMap(\.items)
        .filter { $0.assetID == assetID }
        .map { $0.id.rawValue }
    return ids.isEmpty ? "[]" : "[\(ids.joined(separator: ","))]"
}

private func timelineTargets(
    for assetID: AssetID,
    sourceTime: RationalTime,
    context: ToolExecutionContext
) -> String {
    let targets = context.document.timeline.videoTracks.flatMap(\.items).compactMap {
        item -> String? in
        guard item.assetID == assetID,
            sourceTime >= item.sourceRange.start,
            sourceTime <= item.sourceRange.end
        else { return nil }
        let offset = (sourceTime - item.sourceRange.start).scaled(by: 1 / item.speed)
        return "itemID=\(item.id.rawValue) splitAt=\(searchSeconds(item.timelineStart + offset))s"
    }
    return targets.isEmpty ? "[]" : "[\(targets.joined(separator: ";"))]"
}

private func searchSeconds(_ time: RationalTime) -> String {
    String(format: "%.3f", time.seconds)
}

private func quoted(_ value: AttributedString) -> String {
    quoted(String(value.characters))
}

private func quoted(_ value: String) -> String {
    let compact = value.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(String(compact.prefix(320)))\""
}
