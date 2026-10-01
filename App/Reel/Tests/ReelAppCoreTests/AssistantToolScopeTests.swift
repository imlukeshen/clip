import AIKit
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Assistant tool scope")
struct AssistantToolScopeTests {
    private let pdf = AssistantSessionToken.Document.pdf(DocumentID(rawValue: "pdf"))
    private let timeline = AssistantSessionToken.Document.timeline(ProjectID(rawValue: "project"))

    private func names(
        _ document: AssistantSessionToken.Document, isLocalModel: Bool
    ) -> [String] {
        ToolCatalog.all(
            expanding: AssistantToolScope.categories(for: document, isLocalModel: isLocalModel)
        ).map(\.name)
    }

    @Test("A local model is offered the open workspace's tools, not every workspace's")
    func localModelSeesOpenWorkspaceOnly() {
        let offered = names(pdf, isLocalModel: true)
        #expect(offered.contains("pdf.redactText"))
        // Each schema is context a small model reads before answering, and one
        // more name it can pick by mistake.
        #expect(!offered.contains("timeline.rippleDelete"))
        #expect(!offered.contains("cropTo"))

        let onTimeline = names(timeline, isLocalModel: true)
        #expect(onTimeline.contains("timeline.rippleDelete"))
        #expect(onTimeline.contains("timeline.audioFade"))
        #expect(!onTimeline.contains("pdf.redactText"))
    }

    @Test("A hosted model keeps every workspace's tools")
    func hostedModelSeesEverything() {
        let offered = names(pdf, isLocalModel: false)
        #expect(offered.contains("pdf.redactText"))
        #expect(offered.contains("timeline.rippleDelete"))
        #expect(offered.contains("cropTo"))
    }

    @Test("A local model can still reach another workspace through the meta-tools")
    func discoveryRemainsAvailable() {
        let offered = names(pdf, isLocalModel: true)
        #expect(offered.contains("listCommands"))
        #expect(offered.contains("runCommand"))
        #expect(offered.count < names(pdf, isLocalModel: false).count)
    }
}
