import CoreModel
import Foundation
import Testing

@testable import AIKit

private struct FixtureTransport: HTTPTransport {
    let data: Data
    let status: Int

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let fallbackURL = URL(string: "https://fixture.invalid"),
            let response = HTTPURLResponse(
                url: request.url ?? fallbackURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )
        else { throw AIKitError.invalidResponse("Invalid fixture response") }
        return (data, response)
    }
}

private struct FailedTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw AIKitError.requestFailed(599)
    }
}

private func request() -> ChatRequest {
    ChatRequest(
        model: "fixture-model",
        system: "Use tools.",
        messages: [.init(role: .user, content: "trim and zoom")]
    )
}

@Test func openAIInterleavedToolFragmentsAndOneLedgerEntry() async throws {
    let fixture = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_trim","function":{"name":"trim","arguments":"{\\\"itemID\\\":\\\""}},{"index":1,"id":"call_zoom","function":{"name":"add","arguments":"{\\\"scale\\\":"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"Zoom","arguments":"2}"}},{"index":0,"function":{"name":"Clip","arguments":"one\\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8}}

        data: [DONE]

        """
    let ledger = EgressLedger()
    let provider = OpenAICompatibleProvider(
        baseURL: try #require(URL(string: "http://localhost:1234/v1")),
        defaultModel: "local",
        ledger: ledger,
        transport: FixtureTransport(data: Data(fixture.utf8), status: 200)
    )
    var chunks: [ChatChunk] = []
    for try await chunk in provider.send(request()) { chunks.append(chunk) }

    #expect(
        chunks.contains(
            .toolCall(
                .init(
                    callID: "call_trim", name: "trimClip",
                    arguments: .object(["itemID": .string("one")])))))
    #expect(
        chunks.contains(
            .toolCall(
                .init(
                    callID: "call_zoom", name: "addZoom", arguments: .object(["scale": .number(2)]))
            )))
    #expect(await ledger.summary().requestCount == 1)
}

@Test func anthropicAccumulatesPartialJSONUntilBlockStop() throws {
    let fixture = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":9}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-1","name":"setSpeed"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"itemID\\\":\\\"clip"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"-1\\\",\\\"speed\\\":1.5}"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":11}}

        """
    let chunks = try AnthropicStreamParser.parse(Data(fixture.utf8))
    #expect(
        chunks.contains(
            .toolCall(
                .init(
                    callID: "tool-1", name: "setSpeed",
                    arguments: .object(["itemID": .string("clip-1"), "speed": .number(1.5)])))))
    #expect(chunks.last == .done(.toolUse))
}

@Test func geminiReadsCompleteFunctionCallObject() throws {
    let fixture = """
        data: {"candidates":[{"content":{"parts":[{"text":"Working."},{"functionCall":{"name":"splitClip","args":{"itemID":"one","at":3}}}]}}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":2}}

        """
    let chunks = try GeminiStreamParser.parse(Data(fixture.utf8))
    #expect(
        chunks.contains(
            .toolCall(
                .init(
                    callID: "gemini-1", name: "splitClip",
                    arguments: .object(["itemID": .string("one"), "at": .number(3)])))))
}

@Test func failedOutboundRequestIsStillLoggedExactlyOnce() async throws {
    let ledger = EgressLedger()
    let provider = OpenAICompatibleProvider(
        baseURL: try #require(URL(string: "http://localhost:1234/v1")),
        defaultModel: "local",
        ledger: ledger,
        transport: FailedTransport()
    )
    do {
        for try await _ in provider.send(request()) {}
        Issue.record("Expected transport failure")
    } catch {}
    #expect(await ledger.summary().requestCount == 1)
}
