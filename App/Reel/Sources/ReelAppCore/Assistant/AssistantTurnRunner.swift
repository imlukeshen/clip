import AIKit
import CoreModel
import Foundation

/// One message shown in the editor's assistant rail.
public struct AssistantMessage: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable { case user, assistant, status }
    public var id: String
    public var role: Role
    public var text: String

    public init(id: String = UUID().uuidString, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// A resolved edit waiting for explicit review.
public struct PendingAssistantAction: Sendable, Equatable, Identifiable {
    public var id: String { result.callID }
    public var name: String
    public var result: ToolResult

    public init(name: String, result: ToolResult) {
        self.name = name
        self.result = result
    }
}

/// Provider output and resolved tool results for one outbound request.
public struct AssistantTurn: Sendable, Equatable {
    public var text: String
    public var invocations: [ToolInvocation]
    public var results: [ToolResult]

    public init(text: String, invocations: [ToolInvocation], results: [ToolResult]) {
        self.text = text
        self.invocations = invocations
        self.results = results
    }
}

/// Runs one bounded provider request and resolves all returned tools in order.
public struct AssistantTurnRunner: Sendable {
    private let executor: ToolExecutor

    public init(executor: ToolExecutor = ToolExecutor()) { self.executor = executor }

    public func run(
        prompt: String,
        turnID: String,
        provider: any AIProvider,
        policy: ConfirmationPolicy,
        digest: ContextDigest,
        context initialContext: ToolExecutionContext
    ) async throws -> AssistantTurn {
        let contextJSON = try digest.encodedString()
        let request = ChatRequest(
            model: provider.defaultModel,
            system: Self.systemPrompt,
            messages: [
                .init(
                    role: .user,
                    content: "Project context:\n\(contextJSON)\n\nRequest:\n\(prompt)"
                )
            ],
            tools: provider.supportsTools ? ToolCatalog.all : [],
            purpose: .chat
        )
        var text = ""
        var invocations: [ToolInvocation] = []
        for try await chunk in provider.send(request) {
            switch chunk {
            case .text(let value): text += value
            case .toolCall(let invocation): invocations.append(invocation)
            case .usage, .done: break
            }
        }

        var context = initialContext
        var results: [ToolResult] = []
        for invocation in invocations {
            let result = try await executor.execute(
                invocation, turnID: turnID, policy: policy, context: context)
            results.append(result)
            if let patch = result.patch {
                var candidate = context.document
                _ = try candidate.apply(patch)
                context.document = candidate
            }
        }
        return AssistantTurn(text: text, invocations: invocations, results: results)
    }

    private static let systemPrompt = """
        You are Reel's editing assistant. Use the supplied tools for timeline edits. Keep each
        requested operation as a separate tool call so every edit remains independently undoable.
        Never invent audio or click availability; trust hasAudio and alignment in the context.
        Ask before actions represented by confirm tools.
        """
}
