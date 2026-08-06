import AIKit
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Assistant editor session identity")
struct AssistantSessionTokenTests {
    @Test("Reopening the same project creates a distinct document generation")
    func generationDistinguishesReopenedProject() {
        let project = ProjectID(rawValue: "project-1")
        let original = AssistantSessionToken(document: .timeline(project), generation: 4)
        let reopened = AssistantSessionToken(document: .timeline(project), generation: 5)
        #expect(original != reopened)
    }

    @Test("Pending actions retain the exact originating session")
    func pendingActionRetainsSession() {
        let session = AssistantSessionToken(
            document: .text(DocumentID(rawValue: "document-1")),
            generation: 9
        )
        let result = ToolResult(
            callID: "call-1",
            message: "Apply edit?",
            requiresConfirmation: true
        )
        let action = PendingAssistantAction(
            name: "assistant.turn",
            result: result,
            session: session
        )
        #expect(action.session == session)
    }

    @Test("Edits within one open document create a distinct assistant revision")
    func revisionDistinguishesInFlightEdits() {
        let project = ProjectID(rawValue: "project-1")
        let before = AssistantSessionToken(
            document: .timeline(project),
            generation: 4,
            revision: Data("before".utf8)
        )
        let after = AssistantSessionToken(
            document: .timeline(project),
            generation: 4,
            revision: Data("after".utf8)
        )

        #expect(before != after)
    }
}
