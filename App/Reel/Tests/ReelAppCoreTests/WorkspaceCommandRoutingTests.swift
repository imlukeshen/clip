import AIKit
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Workspace command routing")
struct WorkspaceCommandRoutingTests {
    @Test("A PDF command reaches the PDF workspace")
    func pdfCommandsRoute() async throws {
        // Every pdf.* and image.* tool was registered, offered to the model, and
        // then answered "Unknown tool" — the assistant's executor had no branch
        // for either category, so the model calling one correctly still failed.
        var context = Self.context
        context.pdfCommand = { invocation in "ran \(invocation.name)" }
        let result = try await ToolExecutor().execute(
            invocation("pdf.redactText", ["text": .string("jiawei")]),
            turnID: "turn",
            policy: .autoApply,
            context: context
        )
        #expect(result.message == "ran pdf.redactText")
    }

    @Test("A photo command reaches the photo workspace")
    func imageCommandsRoute() async throws {
        var context = Self.context
        context.imageCommand = { invocation in "ran \(invocation.name)" }
        let result = try await ToolExecutor().execute(
            invocation("suggestRedactions", [:]),
            turnID: "turn",
            policy: .autoApply,
            context: context
        )
        #expect(result.message == "ran suggestRedactions")
    }

    @Test("Routing is by category, so a new tool needs no new branch")
    func routingCoversEveryRegisteredTool() async throws {
        let seen = SeenNames()
        var context = Self.context
        context.pdfCommand = { await seen.record($0.name) }
        context.imageCommand = { await seen.record($0.name) }

        let workspaceTools = CommandRegistry.all.filter {
            ($0.category == .pdf || $0.category == .image) && $0.agentExposure != .never
        }
        #expect(workspaceTools.count >= 17)
        for command in workspaceTools {
            _ = try? await ToolExecutor().execute(
                invocation(command.id.rawValue, [:]),
                turnID: "turn",
                policy: .autoApply,
                context: context
            )
        }
        #expect(await seen.names == Set(workspaceTools.map(\.id.rawValue)))
    }

    @Test("Asking without the workspace open says so rather than failing opaquely")
    func closedWorkspaceExplainsItself() async {
        await #expect(throws: ToolExecutorError.workspaceUnavailable("PDF")) {
            _ = try await ToolExecutor().execute(
                invocation("pdf.redactText", ["text": .string("x")]),
                turnID: "turn",
                policy: .autoApply,
                context: Self.context
            )
        }
    }

    private actor SeenNames {
        private(set) var names: Set<String> = []
        @discardableResult
        func record(_ name: String) -> String {
            names.insert(name)
            return "ok"
        }
    }

    private func invocation(_ name: String, _ arguments: [String: JSONValue]) -> ToolInvocation {
        ToolInvocation(callID: "call", name: name, arguments: .object(arguments))
    }

    private static var context: ToolExecutionContext {
        // swift-format-ignore
        let document = try! ProjectDocument(
            id: ProjectID(rawValue: "routing"),
            name: "Routing",
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
        return ToolExecutionContext(
            document: document,
            assets: [:],
            eventTracks: [:],
            resolving: { id in URL(fileURLWithPath: "/tmp/\(id.rawValue)") }
        )
    }
}
