import AIKit
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Assistant window sharing")
struct AssistantWindowFrameTests {
    @Test("A captured frame reaches the provider with consent set")
    func frameIsAttachedAndConsented() async throws {
        let provider = RecordingProvider()
        _ = try await AssistantTurnRunner().run(
            prompt: "what is this",
            turnID: "turn",
            provider: provider,
            policy: .confirmDestructive,
            digest: Self.digest,
            context: Self.context,
            frame: .png(Data([0x89, 0x50, 0x4E, 0x47]))
        )

        let request = try #require(await provider.lastRequest)
        #expect(request.messages.first?.images.count == 1)
        #expect(request.mediaAttached)
        // Without consent the provider gate refuses the request outright, so a
        // frame that reaches here has to carry it.
        #expect(request.mediaConsent)
    }

    @Test("A turn with no frame reports no media and no consent")
    func noFrameAttachesNothing() async throws {
        let provider = RecordingProvider()
        _ = try await AssistantTurnRunner().run(
            prompt: "trim the first clip",
            turnID: "turn",
            provider: provider,
            policy: .confirmDestructive,
            digest: Self.digest,
            context: Self.context
        )

        let request = try #require(await provider.lastRequest)
        #expect(request.messages.allSatisfy { $0.images.isEmpty })
        #expect(!request.mediaAttached)
        // Consent is not asserted when nothing is attached: the egress ledger
        // would otherwise record every ordinary turn as media-consented.
        #expect(!request.mediaConsent)
    }

    @Test("Every workspace with a chat panel can start a session")
    func sessionDocumentCoversEveryChatWorkspace() {
        // The composer is the same component in four places. Its send silently
        // did nothing wherever this enum had no case, which is how the PDF and
        // photo panels shipped unable to send anything at all.
        let documents: [AssistantSessionToken.Document] = [
            .timeline(ProjectID(rawValue: "p")),
            .text(DocumentID(rawValue: "t")),
            .pdf(DocumentID(rawValue: "d")),
            .image(DocumentID(rawValue: "i")),
        ]
        #expect(Set(documents.map(String.init(describing:))).count == documents.count)
    }

    private static var digest: ContextDigest {
        ContextDigest(
            projectName: "Frames", duration: 6, canvas: "1920x1080@60",
            selectedItemID: nil, items: []
        )
    }

    private static var context: ToolExecutionContext {
        // Force-unwrapped deliberately: a fixed literal document either builds
        // or the test is meaningless, and force unwrapping is allowed in tests.
        // swift-format-ignore
        let document = try! ProjectDocument(
            id: ProjectID(rawValue: "frames"),
            name: "Frames",
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
        return ToolExecutionContext(
            document: document,
            assets: [:],
            eventTracks: [:],
            resolving: { id in URL(fileURLWithPath: "/tmp/\(id.rawValue).mov") }
        )
    }
}

private actor RecordingProvider: AIProvider {
    private(set) var lastRequest: ChatRequest?
    nonisolated var id: ProviderID { .openAICompatible }
    nonisolated var displayName: String { "Recording" }
    nonisolated var supportsTools: Bool { true }
    nonisolated var supportsVision: Bool { true }
    nonisolated var defaultModel: String { "fixture" }

    private func store(_ request: ChatRequest) { lastRequest = request }

    nonisolated func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await store(request)
                continuation.yield(.text("ok"))
                continuation.yield(.done(.complete))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
