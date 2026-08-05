import AIKit
import CoreModel
import Foundation
import LibraryStore
import SearchEngine
import Testing

@testable import ReelAppCore

@Suite("Assistant tool execution")
struct ToolExecutorTests {
    @Test("Every write tool resolves to a valid assistant patch")
    func everyWriteToolProducesValidPatch() async throws {
        let fixture = try Fixture()
        let executor = fixture.executor
        let invocations: [ToolInvocation] = [
            call("trimClip", ["itemID": .string("one"), "start": .number(1), "end": .number(5)]),
            call("splitClip", ["itemID": .string("one"), "at": .number(2)]),
            call("reorderClips", ["order": .array([.string("two"), .string("one")])]),
            call("setSpeed", ["itemID": .string("one"), "speed": .number(1.5)]),
            call(
                "setKeyframe",
                [
                    "property": .string("opacity"), "time": .number(1.25),
                    "value": .number(0.65), "itemID": .string("one"),
                ]
            ),
            call("timeline.rippleDelete", ["itemID": .string("one")]),
            call(
                "timeline.slip",
                ["itemID": .string("one"), "delta": .number(0)]
            ),
            call(
                "timeline.addMarker",
                ["time": .number(2.5), "name": .string("Review")]
            ),
            call(
                "timeline.crossDissolve",
                ["itemID": .string("one"), "duration": .number(0.35)]
            ),
            call(
                "timeline.audioFade",
                ["itemID": .string("one"), "fadeIn": .number(0.2), "fadeOut": .number(0.2)]
            ),
            call(
                "addZoom",
                [
                    "itemID": .string("one"),
                    "range": .object(["start": .number(0), "end": .number(1.5)]),
                    "center": .object(["x": .number(0.4), "y": .number(0.6)]),
                    "scale": .number(1.8),
                ]),
            call(
                "autoZoomFromClicks",
                ["itemIDs": .array([.string("one")]), "options": .object([:])]),
            call("removeEffect", ["itemID": .string("one"), "effectID": .string("existing")]),
            call(
                "setBackground",
                [
                    "itemIDs": .array([.string("one")]), "padding": .number(28),
                    "radius": .number(14),
                    "style": .object([
                        "color": .object([
                            "r": .number(0.1), "g": .number(0.2), "b": .number(0.3),
                            "a": .number(1),
                        ])
                    ]),
                ]),
            call(
                "trimSilence", ["itemIDs": .array([.string("one")]), "thresholdDB": .number(-38)]),
            call(
                "generateCaptions",
                ["itemIDs": .array([.string("one")]), "engine": .string("onDevice")]),
        ]

        for invocation in invocations {
            let result = try await executor.execute(
                invocation,
                turnID: "turn-write",
                policy: .autoApply,
                context: fixture.context
            )
            let patch = try #require(result.patch, "\(invocation.name) did not produce a patch")
            if case .assistant(let turnID) = patch.origin {
                #expect(turnID == "turn-write")
            } else {
                Issue.record("\(invocation.name) did not use assistant origin")
            }
            var candidate = fixture.document
            _ = try candidate.apply(patch)
        }
    }

    @Test("Dead-air plus click zoom is one request and one turn-level undo entry")
    @MainActor
    func acceptanceTurn() async throws {
        let fixture = try Fixture()
        let ledger = EgressLedger()
        let provider = FixtureProvider(
            ledger: ledger,
            chunks: [
                .toolCall(
                    call(
                        "trimSilence",
                        [
                            "itemIDs": .array([.string("one")]), "thresholdDB": .number(-38),
                        ], id: "trim")),
                .toolCall(
                    call(
                        "autoZoomFromClicks",
                        [
                            "itemIDs": .array([.string("one")]), "options": .object([:]),
                        ], id: "zoom")),
                .done(.toolUse),
            ])
        let turn = try await AssistantTurnRunner(executor: fixture.executor).run(
            prompt: "trim the dead air and zoom on the clicks",
            turnID: "acceptance",
            provider: provider,
            policy: .autoApply,
            digest: fixture.digest,
            context: fixture.context
        )
        #expect(turn.invocations.map(\.name) == ["trimSilence", "autoZoomFromClicks"])
        #expect(turn.results.count == 2)
        #expect(await ledger.summary().requestCount == 1)

        let editor = fixture.editor()
        let original = editor.document
        try editor.perform(try #require(turn.combinedPatch))
        #expect(editor.document != original)

        editor.undo()
        #expect(editor.document == original)
    }

    @Test("An on-demand command is discoverable and runnable through meta-tools")
    func onDemandCommandDiscovery() async throws {
        let fixture = try Fixture()
        let listed = try await fixture.executor.execute(
            call("listCommands", ["category": .string("audio")]),
            turnID: "discover",
            policy: .autoApply,
            context: fixture.context
        )
        #expect(listed.message.contains("detectSilence"))

        let result = try await fixture.executor.execute(
            call(
                "runCommand",
                [
                    "id": .string("describeClip"),
                    "arguments": .object(["itemID": .string("one")]),
                ]
            ),
            turnID: "discover",
            policy: .autoApply,
            context: fixture.context
        )
        #expect(result.message.contains("Clip one"))
        #expect(result.message.count < 200)
    }

    @Test("On-device caption tool needs no provider credential")
    func captionsNeedNoKey() async throws {
        let fixture = try Fixture()
        let result = try await fixture.executor.execute(
            call(
                "generateCaptions",
                [
                    "itemIDs": .array([.string("one")]), "engine": .string("onDevice"),
                ]),
            turnID: "captions",
            policy: .autoApply,
            context: fixture.context
        )
        let patch = try #require(result.patch)
        var document = fixture.document
        _ = try document.apply(patch)
        #expect(document.timeline.captions.map(\.text) == ["Welcome to Reel"])
    }

    @Test("Agent search decomposes discovery into one undoable split")
    @MainActor
    func agenticSearchAcceptance() async throws {
        let fixture = try Fixture()
        let ledger = EgressLedger()
        var context = fixture.context
        context.searching = { query in
            #expect(query.text == "error state")
            #expect(query.filters.kind == .video)
            let moment = SearchMoment(
                assetID: AssetID(rawValue: "asset-one"),
                start: RationalTime(seconds: 2),
                end: RationalTime(seconds: 3),
                snippet: AttributedString("Error state"),
                source: .ocr
            )
            return SearchResponse(
                hits: [
                    SearchHit(
                        assetID: moment.assetID,
                        score: 1,
                        moments: [moment],
                        snippet: moment.snippet,
                        sources: [.ocr],
                        isUnavailable: false
                    )
                ],
                isComplete: true
            )
        }
        context.searchingWithin = { assetID, text in
            #expect(assetID == AssetID(rawValue: "asset-one"))
            #expect(text == "error state")
            return [
                SearchMoment(
                    assetID: assetID,
                    start: RationalTime(seconds: 2),
                    end: RationalTime(seconds: 3),
                    snippet: AttributedString("Error state"),
                    source: .ocr
                )
            ]
        }

        let turn = try await AssistantTurnRunner(executor: fixture.executor).run(
            prompt: "find where I showed the error state and split there",
            turnID: "search-acceptance",
            provider: SearchSequenceProvider(ledger: ledger),
            policy: .autoApply,
            digest: fixture.digest,
            context: context
        )

        #expect(
            turn.invocations.map(\.name)
                == ["search.library", "search.withinAsset", "splitClip"]
        )
        #expect(turn.results[1].message.contains("sourceAt=2.000s"))
        #expect(turn.results[1].message.contains("itemID=one splitAt=2.000s"))
        #expect(await ledger.summary().requestCount == 3)

        let editor = fixture.editor()
        let original = editor.document
        try editor.perform(try #require(turn.combinedPatch))
        #expect(editor.document.timeline.video.count == 3)
        editor.undo()
        #expect(editor.document == original)
    }

    @Test("All four search tools are read-only and return actionable context")
    func searchToolContract() async throws {
        let names = [
            "search.library", "search.withinAsset", "search.textAt", "search.similar",
        ]
        for name in names {
            let schema = try #require(CommandRegistry.command(named: name)?.schema)
            #expect(schema.kind == .read)
        }
        let libraryDescription = try #require(
            CommandRegistry.command(named: "search.library")?.schema.description
        )
        #expect(libraryDescription.localizedCaseInsensitiveContains("timestamp"))
        #expect(libraryDescription.localizedCaseInsensitiveContains("quoted"))
        #expect(libraryDescription.localizedCaseInsensitiveContains("exact"))

        let fixture = try Fixture()
        var context = fixture.context
        context.readingText = { assetID, time in
            [
                OCRSpan(
                    assetID: assetID,
                    start: time,
                    end: time + RationalTime(seconds: 1),
                    text: "Fatal error",
                    boundingBox: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                    confidence: 0.99,
                    revision: 1,
                    script: .alphabetic
                )
            ]
        }
        context.searchingSimilar = { _, _ in
            [
                SearchHit(
                    assetID: AssetID(rawValue: "asset-two"),
                    score: 0.91,
                    moments: [],
                    snippet: AttributedString("Similar setup"),
                    sources: [.ocr],
                    isUnavailable: false
                )
            ]
        }
        let text = try await fixture.executor.execute(
            call(
                "search.textAt",
                ["assetID": .string("asset-one"), "time": .number(2)]
            ),
            turnID: "search-contract",
            policy: .autoApply,
            context: context
        )
        #expect(text.patch == nil)
        #expect(text.message.contains("Fatal error"))
        let similar = try await fixture.executor.execute(
            call(
                "search.similar",
                ["assetID": .string("asset-one"), "limit": .number(5)]
            ),
            turnID: "search-contract",
            policy: .autoApply,
            context: context
        )
        #expect(similar.patch == nil)
        #expect(similar.message.contains("asset-two"))
    }
}

private struct FixtureProvider: AIProvider {
    let ledger: EgressLedger
    let chunks: [ChatChunk]
    var id: ProviderID { .openAICompatible }
    var displayName: String { "Fixture" }
    var supportsTools: Bool { true }
    var supportsVision: Bool { false }
    var defaultModel: String { "fixture" }

    func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await ledger.record(
                    EgressEntry(
                        provider: id, model: request.model, purpose: request.purpose,
                        mediaAttached: request.mediaAttached))
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct SearchSequenceProvider: AIProvider {
    let ledger: EgressLedger
    var id: ProviderID { .openAICompatible }
    var displayName: String { "Search Fixture" }
    var supportsTools: Bool { true }
    var supportsVision: Bool { false }
    var defaultModel: String { "fixture" }

    func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let invocation: ToolInvocation
        switch request.messages.count {
        case 1:
            invocation = call(
                "search.library",
                ["text": .string("error state"), "kind": .string("video")],
                id: "library"
            )
        case 3:
            invocation = call(
                "search.withinAsset",
                ["assetID": .string("asset-one"), "text": .string("error state")],
                id: "within"
            )
        default:
            invocation = call(
                "splitClip",
                ["itemID": .string("one"), "at": .number(2)],
                id: "split"
            )
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                await ledger.record(
                    EgressEntry(
                        provider: id,
                        model: request.model,
                        purpose: request.purpose,
                        mediaAttached: request.mediaAttached
                    )
                )
                continuation.yield(.toolCall(invocation))
                continuation.yield(.done(.toolUse))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct Fixture {
    let document: ProjectDocument
    let assets: [AssetID: AssetRecord]
    let tracks: [AssetID: EventTrack]
    let executor: ToolExecutor

    init() throws {
        let firstAsset = AssetID(rawValue: "asset-one")
        let secondAsset = AssetID(rawValue: "asset-two")
        let existing = BackgroundEffect(
            id: EffectID(rawValue: "existing"),
            range: TimeRange(start: .zero, duration: RationalTime(seconds: 6)),
            padding: 20,
            cornerRadius: 8,
            style: .solid(.black)
        )
        self.document = try ProjectDocument(
            id: ProjectID(rawValue: "project"),
            name: "Acceptance",
            timeline: Timeline(video: [
                TimelineItem(
                    id: ItemID(rawValue: "one"),
                    assetID: firstAsset,
                    sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 6)),
                    effects: [.background(existing)]
                ),
                TimelineItem(
                    id: ItemID(rawValue: "two"),
                    assetID: secondAsset,
                    sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 4))
                ),
            ]),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        self.assets = [
            firstAsset: Self.asset(firstAsset, duration: 6),
            secondAsset: Self.asset(secondAsset, duration: 4),
        ]
        let track = EventTrack(
            assetID: firstAsset,
            alignment: .exact(offset: .zero),
            samples: [],
            clicks: [
                ClickEvent(
                    time: RationalTime(seconds: 2),
                    point: NormalizedPoint(x: 0.6, y: 0.4),
                    button: .left,
                    clickCount: 1,
                )
            ]
        )
        self.tracks = [firstAsset: track]
        self.executor = ToolExecutor(
            silenceTrimmer: { _, _ in
                TimeRange(start: RationalTime(seconds: 1), duration: RationalTime(seconds: 4))
            },
            transcriber: { _ in
                Transcript(
                    text: "Welcome to Reel",
                    segments: [.init(start: 1, duration: 1.5, text: "Welcome to Reel")]
                )
            }
        )
    }

    var context: ToolExecutionContext {
        ToolExecutionContext(
            document: document,
            assets: assets,
            eventTracks: tracks,
            resolving: { id in URL(fileURLWithPath: "/tmp/\(id.rawValue).mov") }
        )
    }

    var digest: ContextDigest {
        ContextDigest(
            projectName: "Acceptance", duration: 10, canvas: "1920x1080@60",
            selectedItemID: "one",
            items: [
                ContextItem(
                    id: "one", name: "First", duration: 6, hasAudio: true,
                    clicks: 1, effects: ["background×1"], alignment: "exact",
                )
            ]
        )
    }

    @MainActor
    func editor() -> EditorViewModel {
        EditorViewModel(
            document: document,
            assets: assets,
            eventTracks: tracks,
            clickTrackingState: .enabled(bufferDurationSeconds: 300),
            buildsPlayback: false,
            resolving: { id in URL(fileURLWithPath: "/tmp/\(id.rawValue).mov") },
            persisting: { _, _ in }
        )
    }

    private static func asset(_ id: AssetID, duration: Double) -> AssetRecord {
        AssetRecord(
            id: id,
            relativePath: "Assets/\(id.rawValue).mov",
            displayName: "\(id.rawValue).mov",
            kind: .video,
            createdAt: Date(timeIntervalSince1970: 1),
            importedAt: Date(timeIntervalSince1970: 1),
            byteSize: 1,
            contentHash: id.rawValue,
            duration: RationalTime(seconds: duration),
            hasAudio: true,
            eventAlignment: .exact,
            ingestState: .ready
        )
    }
}

private func call(
    _ name: String,
    _ arguments: [String: JSONValue],
    id: String = UUID().uuidString
) -> ToolInvocation {
    ToolInvocation(callID: id, name: name, arguments: .object(arguments))
}
