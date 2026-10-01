import CoreModel
import Foundation
import Testing

@testable import AIKit

private actor SentRequests {
    private(set) var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

private struct NativeTransport: HTTPTransport {
    let log: SentRequests
    var reply = #"{"message":{"role":"assistant","content":""},"done":true}"#

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await log.append(request)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw AIKitError.invalidResponse("fixture") }
        return (Data(reply.utf8), response)
    }
}

@Suite("Ollama native chat")
struct OllamaChatProviderTests {
    private func provider(
        log: SentRequests,
        supportsTools: Bool = true,
        supportsVision: Bool = false
    ) throws -> OllamaChatProvider {
        OllamaChatProvider(
            baseURL: try #require(URL(string: "http://localhost:11434")),
            defaultModel: "qwen3:4b",
            supportsTools: supportsTools,
            supportsVision: supportsVision,
            ledger: EgressLedger(),
            transport: NativeTransport(log: log)
        )
    }

    private func sentBody(_ log: SentRequests) async throws -> JSONValue {
        let body = try #require(await log.requests.first?.httpBody)
        return try JSONDecoder().decode(JSONValue.self, from: body)
    }

    @Test("The request asks for a context window that holds the tool catalog")
    func requestSetsContextLength() async throws {
        let log = SentRequests()
        let request = ChatRequest(
            model: "qwen3:4b", system: "Use tools.",
            messages: [.init(role: .user, content: "trim it")])
        for try await _ in try provider(log: log).send(request) {}

        let sent = try #require(await log.requests.first)
        #expect(sent.url?.absoluteString == "http://localhost:11434/api/chat")
        let body = try await sentBody(log)
        // The compatible endpoint has no field for this, which is the whole
        // reason the native one is used: at the server's 4,096 default the
        // prompt was cut to less than half before the model read it.
        #expect(
            body["options"]?["num_ctx"]
                == .number(Double(OllamaChatProvider.defaultContextLength)))
        #expect(body["options"]?["num_predict"] == .number(Double(request.maxTokens)))
        #expect(OllamaChatProvider.defaultContextLength > 4_096)
        #expect(body["stream"] == .bool(true))
        guard case .array(let tools)? = body["tools"] else {
            Issue.record("Expected tool schemas")
            return
        }
        #expect(tools.count == ToolCatalog.all.count)
        guard case .array(let messages)? = body["messages"] else {
            Issue.record("Expected messages")
            return
        }
        #expect(messages.first?["role"] == .string("system"))
        #expect(messages.last?["content"] == .string("trim it"))
    }

    @Test("A model without tool support is not sent schemas")
    func toolsOmittedWhenUnsupported() async throws {
        let log = SentRequests()
        let request = ChatRequest(
            model: "llava:7b", system: "", messages: [.init(role: .user, content: "hi")])
        for try await _ in try provider(log: log, supportsTools: false).send(request) {}
        #expect(try await sentBody(log)["tools"] == nil)
    }

    @Test("Images travel as bare base64, not a data URL")
    func imagesUseNativeShape() async throws {
        let log = SentRequests()
        let image = ChatImage.png(Data([0x89, 0x50, 0x4E, 0x47]))
        let request = ChatRequest(
            model: "llava:7b", system: "",
            messages: [.init(role: .user, content: "what is this", images: [image])],
            tools: [], mediaConsent: true)
        for try await _ in try provider(log: log, supportsVision: true).send(request) {}

        guard case .array(let messages)? = try await sentBody(log)["messages"] else {
            Issue.record("Expected messages")
            return
        }
        #expect(messages.last?["images"] == .array([.string(image.base64)]))
    }

    @Test("Thinking is dropped; text, tool calls, and usage are read")
    func parsesNativeStream() throws {
        let fixture = """
            {"message":{"role":"assistant","content":"","thinking":"Okay, trim."},"done":false}
            {"message":{"role":"assistant","content":"Trimming."},"done":false}
            {"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","function":{"index":0,"name":"trimClip","arguments":{"itemID":"abc","start":2,"end":5}}}]},"done":false}
            {"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":162,"eval_count":430}
            """
        let chunks = try OllamaStreamParser.parse(Data(fixture.utf8))
        #expect(
            chunks == [
                .text("Trimming."),
                .toolCall(
                    .init(
                        callID: "call_1", name: "trimClip",
                        arguments: .object([
                            "itemID": .string("abc"), "start": .number(2), "end": .number(5),
                        ]))),
                .usage(inputTokens: 162, outputTokens: 430),
                .done(.toolUse),
            ])
    }

    @Test("Calls without an ID get distinct ones, and string arguments are decoded")
    func toleratesOlderCallShapes() throws {
        let fixture = """
            {"message":{"content":"","tool_calls":[{"function":{"name":"splitClip","arguments":"{\\"itemID\\":\\"one\\",\\"at\\":3}"}},{"function":{"name":"describeTimeline"}}]},"done":true}
            """
        let calls = try OllamaStreamParser.parse(Data(fixture.utf8)).compactMap {
            chunk -> ToolInvocation? in
            if case .toolCall(let invocation) = chunk { invocation } else { nil }
        }
        #expect(calls.map(\.callID) == ["ollama-1", "ollama-2"])
        #expect(calls.first?.arguments == .object(["itemID": .string("one"), "at": .number(3)]))
        #expect(calls.last?.arguments == .object([:]))
    }

    @Test("A reply cut off by the token limit says so")
    func reportsTruncatedReply() throws {
        let fixture = #"{"message":{"content":"half an ans"},"done":true,"done_reason":"length"}"#
        #expect(try OllamaStreamParser.parse(Data(fixture.utf8)).last == .done(.maxTokens))
    }

    @Test("A server error line fails the request with its message")
    func surfacesErrorLine() {
        let fixture = #"{"error":"model requires more system memory"}"#
        #expect(throws: AIKitError.invalidResponse("model requires more system memory")) {
            try OllamaStreamParser.parse(Data(fixture.utf8))
        }
    }
}
