import AIKit
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@Suite("T7 text tool integration")
struct TextToolIntegrationTests {
    @Test("The six text commands are first-class agent tools")
    func commandContract() throws {
        let expected = [
            "text.create", "text.setLanguage", "text.format", "tex.compile",
            "tex.diagnostics", "text.export",
        ]

        for name in expected {
            let command = try #require(CommandRegistry.command(named: name))
            #expect(command.category == .text)
            #expect(command.agentExposure == .always)
            #expect(command.schema.hasValidObjectSchema)
            #expect(ToolCatalog.schema(named: name) != nil)
        }
        #expect(CommandRegistry.command(named: "tex.diagnostics")?.schema.kind == .read)
        #expect(CommandRegistry.command(named: "text.export")?.schema.kind == .confirm)
    }

    @Test("Compile diagnostics and line edits execute in agent order")
    func latexRepairSequence() async throws {
        let recorder = TextToolRecorder()
        let context = try toolContext { request in await recorder.execute(request) }
        let executor = ToolExecutor()

        _ = try await executor.execute(
            invocation("tex.compile"),
            turnID: "repair",
            policy: .confirmDestructive,
            context: context
        )
        _ = try await executor.execute(
            invocation("tex.diagnostics"),
            turnID: "repair",
            policy: .confirmDestructive,
            context: context
        )
        _ = try await executor.execute(
            invocation(
                "text.format",
                arguments: [
                    "edits": .array([
                        .object([
                            "startLine": .number(3),
                            "endLine": .number(3),
                            "replacement": .string("\\end{document}\n"),
                        ])
                    ])
                ]
            ),
            turnID: "repair",
            policy: .confirmDestructive,
            context: context
        )
        _ = try await executor.execute(
            invocation("tex.compile"),
            turnID: "repair",
            policy: .confirmDestructive,
            context: context
        )

        #expect(
            await recorder.requests() == [
                .compileTeX,
                .diagnostics,
                .format(
                    TextToolFormatRequest(
                        edits: [
                            TextToolLineEdit(
                                startLine: 3,
                                endLine: 3,
                                replacement: "\\end{document}\n"
                            )
                        ]
                    )
                ),
                .compileTeX,
            ]
        )
    }

    @Test("External exports and confirm-all text edits do not run before approval")
    func sideEffectConfirmation() async throws {
        let recorder = TextToolRecorder()
        let context = try toolContext { request in await recorder.execute(request) }
        let executor = ToolExecutor()
        let destination = "/tmp/clip-export.html"

        let export = try await executor.execute(
            invocation(
                "text.export",
                arguments: [
                    "format": .string("html"),
                    "destination": .string(destination),
                ]
            ),
            turnID: "export",
            policy: .autoApply,
            context: context
        )
        #expect(export.requiresConfirmation)
        #expect(await recorder.requests().isEmpty)

        let format = try await executor.execute(
            invocation(
                "text.format",
                arguments: ["trimTrailingWhitespace": .bool(true)]
            ),
            turnID: "format",
            policy: .confirmAll,
            context: context
        )
        #expect(format.requiresConfirmation)
        #expect(await recorder.requests().isEmpty)

        _ = try await executor.execute(
            invocation(
                "text.export",
                arguments: [
                    "format": .string("html"),
                    "destination": .string(destination),
                ]
            ),
            turnID: "export",
            policy: .autoApply,
            context: context,
            confirmed: true
        )
        #expect(await recorder.requests() == [.export(format: "html", destination: destination)])
    }

    @Test("One assistant turn can compile diagnose repair and verify LaTeX")
    func agenticLatexRepair() async throws {
        let recorder = TextToolRecorder()
        let context = try toolContext { request in await recorder.execute(request) }
        let turn = try await AssistantTurnRunner().run(
            prompt: "Fix the LaTeX errors and verify the document.",
            turnID: "latex-agent",
            provider: TextRepairProvider(),
            policy: .confirmDestructive,
            digest: ContextDigest(
                projectName: "main.tex",
                duration: 0,
                canvas: "text:latex",
                selectedItemID: nil,
                items: []
            ),
            context: context
        )

        #expect(
            turn.invocations.map(\.name) == [
                "tex.compile", "tex.diagnostics", "text.format", "tex.compile",
                "tex.diagnostics",
            ]
        )
        #expect(turn.text == "The corrected document compiles cleanly.")
        #expect(await recorder.requests().count == 5)
    }

    @MainActor
    @Test("Structured line edits share the editor undo stack")
    func formatUndo() throws {
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "main.tex")
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file]),
            text: "one\ntwo   \nthree\n",
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in }
        )

        let changes = try editor.applyToolFormat(
            TextToolFormatRequest(
                edits: [TextToolLineEdit(startLine: 2, endLine: 2, replacement: "fixed   \n")],
                trimsTrailingWhitespace: true
            )
        )

        #expect(changes == 1)
        #expect(editor.text == "one\nfixed\nthree\n")
        #expect(editor.undoManager.canUndo)
        editor.undo()
        #expect(editor.text == "one\ntwo   \nthree\n")
    }

    private func toolContext(
        textCommand: @escaping ToolExecutionContext.TextCommander
    ) throws -> ToolExecutionContext {
        let now = Date(timeIntervalSince1970: 1)
        return ToolExecutionContext(
            document: try ProjectDocument(
                id: ProjectID(rawValue: "text-tools"),
                name: "Text tools",
                createdAt: now,
                modifiedAt: now
            ),
            assets: [:],
            eventTracks: [:],
            resolving: { _ in URL(fileURLWithPath: "/tmp/unavailable") },
            textCommand: textCommand
        )
    }

    private func invocation(
        _ name: String,
        arguments: [String: JSONValue] = [:]
    ) -> ToolInvocation {
        ToolInvocation(
            callID: UUID().uuidString,
            name: name,
            arguments: .object(arguments)
        )
    }
}

private actor TextToolRecorder {
    private var values: [TextToolRequest] = []

    func execute(_ request: TextToolRequest) -> String {
        values.append(request)
        return "ok"
    }

    func requests() -> [TextToolRequest] { values }
}

private struct TextRepairProvider: AIProvider {
    var id: ProviderID { .openAICompatible }
    var displayName: String { "Text Repair Fixture" }
    var supportsTools: Bool { true }
    var supportsVision: Bool { false }
    var defaultModel: String { "fixture" }

    func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let output: ChatChunk
        switch request.messages.count {
        case 1:
            output = .toolCall(tool("tex.compile"))
        case 3:
            output = .toolCall(tool("tex.diagnostics"))
        case 5:
            output = .toolCall(
                tool(
                    "text.format",
                    arguments: [
                        "edits": .array([
                            .object([
                                "startLine": .number(3),
                                "endLine": .number(3),
                                "replacement": .string("\\end{document}\n"),
                            ])
                        ])
                    ]
                )
            )
        case 7:
            output = .toolCall(tool("tex.compile"))
        case 9:
            output = .toolCall(tool("tex.diagnostics"))
        default:
            output = .text("The corrected document compiles cleanly.")
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.yield(.done(output.isText ? .complete : .toolUse))
            continuation.finish()
        }
    }

    private func tool(
        _ name: String,
        arguments: [String: JSONValue] = [:]
    ) -> ToolInvocation {
        ToolInvocation(
            callID: "\(name)-\(arguments.count)",
            name: name,
            arguments: .object(arguments)
        )
    }
}

extension ChatChunk {
    fileprivate var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
