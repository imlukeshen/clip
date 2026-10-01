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

private actor RequestLog {
    private(set) var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

private struct RecordingTransport: HTTPTransport {
    let log: RequestLog
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await log.append(request)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw AIKitError.invalidResponse("fixture") }
        return (Data("data: [DONE]\n\n".utf8), response)
    }
}

@Test func geminiSendsItsKeyInAHeaderNotTheURL() async throws {
    let log = RequestLog()
    let provider = GoogleProvider(
        apiKey: "secret-key", ledger: EgressLedger(), transport: RecordingTransport(log: log))
    for try await _ in provider.send(request()) {}
    let sent = try #require(await log.requests.first)
    #expect(sent.url?.absoluteString.contains("secret-key") == false)
    #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "secret-key")
}

@Test func openAIUsesMaxCompletionTokensAndLocalServersKeepMaxTokens() async throws {
    let openAILog = RequestLog()
    let openAI = OpenAIProvider(
        apiKey: "k", ledger: EgressLedger(), transport: RecordingTransport(log: openAILog))
    for try await _ in openAI.send(request()) {}
    let openAIBody = try #require(await openAILog.requests.first?.httpBody)
    let openAIJSON = try #require(String(data: openAIBody, encoding: .utf8))
    #expect(openAIJSON.contains("max_completion_tokens"))
    #expect(!openAIJSON.contains("\"max_tokens\""))

    let localLog = RequestLog()
    let local = OpenAICompatibleProvider(
        baseURL: try #require(URL(string: "http://localhost:11434/v1")),
        defaultModel: "local",
        ledger: EgressLedger(),
        transport: RecordingTransport(log: localLog)
    )
    for try await _ in local.send(request()) {}
    let localBody = try #require(await localLog.requests.first?.httpBody)
    #expect(String(data: localBody, encoding: .utf8)?.contains("\"max_tokens\"") == true)
}
