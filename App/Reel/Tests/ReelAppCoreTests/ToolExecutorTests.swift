import AIKit
import CoreModel
import Foundation
import LibraryStore
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

    @Test("Dead-air plus click zoom is one request and two independent undo entries")
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
        try editor.perform(try #require(turn.results[0].patch))
        let afterTrim = editor.document
        try editor.perform(try #require(turn.results[1].patch))
        #expect(editor.document != afterTrim)

        editor.undo()
        #expect(editor.document == afterTrim)
        editor.undo()
        #expect(editor.document == original)
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
