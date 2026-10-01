import CoreModel
import Foundation
import Testing

@testable import AIKit

@Suite("Tool turn encoding")
struct ToolTurnEncodingTests {
    /// One read round: the model searched, clipx answered, and the request
    /// continues.
    private func request() -> ChatRequest {
        ChatRequest(
            model: "m", system: "s",
            messages: [
                .init(role: .user, content: "find the error"),
                .init(
                    role: .assistant, content: "",
                    toolCalls: [
                        .init(
                            callID: "call_1", name: "search.library",
                            arguments: .object(["text": .string("error")]))
                    ]),
                .init(
                    role: .user, content: "Continue the original request.",
                    toolResults: [
                        .init(callID: "call_1", name: "search.library", content: "1 result: clip-7")
                    ]),
            ],
            tools: [])
    }

    private func messages(_ body: JSONValue, key: String = "messages") throws -> [JSONValue] {
        guard case .array(let values)? = body[key] else {
            Issue.record("Expected \(key)")
            return []
        }
        return values
    }

    @Test("OpenAI-compatible servers get the call on the assistant message and a tool message back")
    func openAIShape() throws {
        let sent = try messages(try openAIRequestBody(request(), supportsTools: true))
        // system, user, assistant, tool, user
        #expect(sent.count == 5)
        let call = sent[2]["tool_calls"].flatMap { value -> JSONValue? in
            if case .array(let calls) = value { calls.first } else { nil }
        }
        #expect(sent[2]["role"] == .string("assistant"))
        #expect(call?["id"] == .string("call_1"))
        #expect(call?["type"] == .string("function"))
        #expect(call?["function"]?["name"] == .string("search.library"))
        // A JSON string, not an object: that is what the API defines.
        #expect(call?["function"]?["arguments"] == .string(#"{"text":"error"}"#))
        #expect(sent[3]["role"] == .string("tool"))
        #expect(sent[3]["tool_call_id"] == .string("call_1"))
        #expect(sent[3]["content"] == .string("1 result: clip-7"))
        #expect(sent[4]["role"] == .string("user"))
        #expect(sent[4]["content"] == .string("Continue the original request."))
    }

    @Test("Ollama gets arguments as an object and results by tool name")
    func ollamaShape() throws {
        let sent = try messages(
            ollamaRequestBody(request(), supportsTools: true, contextLength: 8_192))
        #expect(sent.count == 5)
        let call = sent[2]["tool_calls"].flatMap { value -> JSONValue? in
            if case .array(let calls) = value { calls.first } else { nil }
        }
        #expect(call?["function"]?["arguments"] == .object(["text": .string("error")]))
        #expect(sent[3]["role"] == .string("tool"))
        #expect(sent[3]["tool_name"] == .string("search.library"))
        #expect(sent[4]["content"] == .string("Continue the original request."))
    }

    @Test("Anthropic and Gemini keep the prose form they were sent before")
    func proseAdaptersAreUnchanged() throws {
        let called = "Called tools: search.library"
        let results =
            "Tool results:\n[call_1 search.library] 1 result: clip-7\n\nContinue the original request."

        let anthropic = try messages(anthropicRequestBody(request()))
        #expect(anthropic.map { $0["content"] }.suffix(2) == [.string(called), .string(results)])

        let gemini = try messages(geminiRequestBody(request()), key: "contents")
        let texts = gemini.suffix(2).map { content -> JSONValue? in
            if case .array(let parts)? = content["parts"] { parts.first?["text"] } else { nil }
        }
        #expect(texts == [.string(called), .string(results)])
    }

    @Test("A compatible server that sends no call ID still gets distinct ones")
    func missingIDsAreFilled() throws {
        let fixture = """
            data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"trimClip","arguments":"{}"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"addZoom","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
        let ids = try OpenAIStreamParser.parse(Data(fixture.utf8)).compactMap {
            chunk -> String? in
            if case .toolCall(let invocation) = chunk { invocation.callID } else { nil }
        }
        #expect(ids == ["call-0", "call-1"])
    }
}
