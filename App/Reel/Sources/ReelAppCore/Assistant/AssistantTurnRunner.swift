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
    public var combinedPatch: GraphPatch?

    public init(
        text: String,
        invocations: [ToolInvocation],
        results: [ToolResult],
        combinedPatch: GraphPatch? = nil
    ) {
        self.text = text
        self.invocations = invocations
        self.results = results
        self.combinedPatch = combinedPatch
    }
}

/// Runs one bounded assistant turn, feeding read-tool results back to the model
/// so it can decompose discovery into a later edit. All writes are still
/// coalesced into one graph patch and therefore one undo entry.
public struct AssistantTurnRunner: Sendable {
    private static let maximumToolCalls = 25
    private static let maximumReadRounds = 8
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
        var messages: [ChatMessage] = [
            .init(
                role: .user,
                content: "Project context:\n\(contextJSON)\n\nRequest:\n\(prompt)"
            )
        ]
        var text = ""
        var invocations: [ToolInvocation] = []
        var context = initialContext
        var results: [ToolResult] = []
        var reachedToolLimit = false

        for round in 0..<Self.maximumReadRounds {
            let request = ChatRequest(
                model: provider.defaultModel,
                system: Self.systemPrompt,
                messages: messages,
                tools: provider.supportsTools ? ToolCatalog.all : [],
                purpose: .chat
            )
            var roundText = ""
            var roundInvocations: [ToolInvocation] = []
            for try await chunk in provider.send(request) {
                switch chunk {
                case .text(let value): roundText += value
                case .toolCall(let invocation): roundInvocations.append(invocation)
                case .usage, .done: break
                }
            }
            if !roundText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !text.isEmpty { text += "\n" }
                text += roundText
            }

            let remaining = Self.maximumToolCalls - invocations.count
            if roundInvocations.count > remaining {
                roundInvocations = Array(roundInvocations.prefix(max(remaining, 0)))
                reachedToolLimit = true
            }
            invocations.append(contentsOf: roundInvocations)

            var roundResults: [ToolResult] = []
            for invocation in roundInvocations {
                let result = try await executor.execute(
                    invocation, turnID: turnID, policy: policy, context: context)
                roundResults.append(result)
                results.append(result)
                if let patch = result.patch {
                    var candidate = context.document
                    _ = try candidate.apply(patch)
                    context.document = candidate
                }
            }

            guard !roundInvocations.isEmpty, !reachedToolLimit else { break }
            let containsWrite = roundInvocations.contains { invocation in
                ToolCatalog.schema(named: invocation.name)?.kind != .read
            }
            guard !containsWrite, round + 1 < Self.maximumReadRounds else { break }

            let called = roundInvocations.map(\.name).joined(separator: ", ")
            messages.append(
                .init(
                    role: .assistant,
                    content: roundText.isEmpty ? "Called tools: \(called)" : roundText
                )
            )
            let feedback = zip(roundInvocations, roundResults).map { invocation, result in
                "[\(invocation.callID) \(invocation.name)] \(result.message)"
            }.joined(separator: "\n")
            messages.append(
                .init(
                    role: .user,
                    content:
                        "Tool results:\n\(feedback)\n\nContinue the original request. Use another tool when needed; do not repeat a completed search."
                )
            )
        }

        if reachedToolLimit {
            text += " I reached the 25-command turn limit. Ask me to continue for the remainder."
        }
        let patches = results.compactMap(\.patch)
        let combinedPatch: GraphPatch? =
            patches.isEmpty
            ? nil
            : GraphPatch(
                ops: patches.flatMap(\.ops),
                label: "Assistant: \(String(prompt.prefix(72)))",
                origin: .assistant(turnID: turnID)
            )
        return AssistantTurn(
            text: text,
            invocations: invocations,
            results: results,
            combinedPatch: combinedPatch
        )
    }

    private static let systemPrompt = """
        You are Clip's editing assistant. Use the supplied tools for timeline edits. Keep each
        requested operation as a separate tool call. Clip coalesces the completed turn into one undo.
        Never invent audio or click availability; trust hasAudio and alignment in the context.
        For requests that refer to visible or spoken content, decompose the task: search the library,
        search within the chosen asset for an exact source timestamp, then edit the corresponding
        timeline item. Search results include timestamps and item IDs. Quoted search text is exact.
        Ask before actions represented by confirm tools.
        """
}
