import CoreModel
import Foundation

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AIKitError.invalidResponse("Missing HTTP response")
        }
        return (data, response)
    }
}

private struct ProviderConfiguration: Sendable {
    var id: ProviderID
    var displayName: String
    var baseURL: URL
    var apiKey: String?
    var defaultModel: String
    var supportsTools: Bool
    var supportsVision: Bool
    var ledger: EgressLedger
    var transport: any HTTPTransport
}

/// An adapter for OpenAI's Chat Completions stream.
public struct OpenAIProvider: AIProvider {
    private let adapter: OpenAICompatibleProvider
    public var id: ProviderID { .openAI }
    public var displayName: String { "OpenAI" }
    public var supportsTools: Bool { true }
    public var supportsVision: Bool { true }
    public var defaultModel: String { adapter.defaultModel }

    public init(apiKey: String, ledger: EgressLedger, defaultModel: String = "gpt-5.6-sol") {
        self.adapter = OpenAICompatibleProvider(
            id: .openAI,
            displayName: "OpenAI",
            baseURL: requiredURL("https://api.openai.com/v1"),
            apiKey: apiKey,
            defaultModel: defaultModel,
            supportsTools: true,
            supportsVision: true,
            ledger: ledger
        )
    }

    init(apiKey: String, ledger: EgressLedger, transport: any HTTPTransport) {
        self.adapter = OpenAICompatibleProvider(
            id: .openAI,
            displayName: "OpenAI",
            baseURL: requiredURL("https://api.openai.com/v1"),
            apiKey: apiKey,
            defaultModel: "gpt-5.6-sol",
            supportsTools: true,
            supportsVision: true,
            ledger: ledger,
            transport: transport
        )
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        adapter.send(request)
    }
}

/// A configurable Chat Completions adapter for local and compatible servers.
public struct OpenAICompatibleProvider: AIProvider {
    private let configuration: ProviderConfiguration
    public var id: ProviderID { configuration.id }
    public var displayName: String { configuration.displayName }
    public var supportsTools: Bool { configuration.supportsTools }
    public var supportsVision: Bool { configuration.supportsVision }
    public var defaultModel: String { configuration.defaultModel }

    public init(
        id: ProviderID = .openAICompatible,
        displayName: String = "OpenAI Compatible",
        baseURL: URL,
        apiKey: String? = nil,
        defaultModel: String,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        ledger: EgressLedger
    ) {
        self.init(
            id: id,
            displayName: displayName,
            baseURL: baseURL,
            apiKey: apiKey,
            defaultModel: defaultModel,
            supportsTools: supportsTools,
            supportsVision: supportsVision,
            ledger: ledger,
            transport: URLSessionTransport()
        )
    }

    init(
        id: ProviderID = .openAICompatible,
        displayName: String = "OpenAI Compatible",
        baseURL: URL,
        apiKey: String? = nil,
        defaultModel: String,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        ledger: EgressLedger,
        transport: any HTTPTransport
    ) {
        self.configuration = ProviderConfiguration(
            id: id,
            displayName: displayName,
            baseURL: baseURL,
            apiKey: apiKey,
            defaultModel: defaultModel,
            supportsTools: supportsTools,
            supportsVision: supportsVision,
            ledger: ledger,
            transport: transport
        )
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validateMedia(request, supportsVision: configuration.supportsVision)
                    let url = configuration.baseURL.appendingPathComponent("chat/completions")
                    let body = openAIRequestBody(
                        request, supportsTools: configuration.supportsTools)
                    var urlRequest = try jsonRequest(url: url, body: body)
                    if let apiKey = configuration.apiKey, !apiKey.isEmpty {
                        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    await record(request, configuration: configuration)
                    let (data, response) = try await configuration.transport.data(for: urlRequest)
                    try validate(response)
                    for chunk in try OpenAIStreamParser.parse(data) { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// An adapter for Anthropic's Messages SSE stream.
public struct AnthropicProvider: AIProvider {
    private let configuration: ProviderConfiguration
    public var id: ProviderID { .anthropic }
    public var displayName: String { "Anthropic" }
    public var supportsTools: Bool { true }
    public var supportsVision: Bool { true }
    public var defaultModel: String { configuration.defaultModel }

    public init(apiKey: String, ledger: EgressLedger, defaultModel: String = "claude-sonnet-4-6") {
        self.init(
            apiKey: apiKey, ledger: ledger, defaultModel: defaultModel,
            transport: URLSessionTransport())
    }

    init(
        apiKey: String, ledger: EgressLedger, defaultModel: String = "claude-sonnet-4-6",
        transport: any HTTPTransport
    ) {
        self.configuration = ProviderConfiguration(
            id: .anthropic,
            displayName: "Anthropic",
            baseURL: requiredURL("https://api.anthropic.com/v1"),
            apiKey: apiKey,
            defaultModel: defaultModel,
            supportsTools: true,
            supportsVision: true,
            ledger: ledger,
            transport: transport
        )
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validateMedia(request, supportsVision: true)
                    let body = anthropicRequestBody(request)
                    var urlRequest = try jsonRequest(
                        url: configuration.baseURL.appendingPathComponent("messages"), body: body)
                    urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    await record(request, configuration: configuration)
                    let (data, response) = try await configuration.transport.data(for: urlRequest)
                    try validate(response)
                    for chunk in try AnthropicStreamParser.parse(data) { continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// An adapter for Google's Gemini streamGenerateContent SSE endpoint.
public struct GoogleProvider: AIProvider {
    private let configuration: ProviderConfiguration
    public var id: ProviderID { .google }
    public var displayName: String { "Google" }
    public var supportsTools: Bool { true }
    public var supportsVision: Bool { true }
    public var defaultModel: String { configuration.defaultModel }

    public init(apiKey: String, ledger: EgressLedger, defaultModel: String = "gemini-2.5-flash") {
        self.init(
            apiKey: apiKey, ledger: ledger, defaultModel: defaultModel,
            transport: URLSessionTransport())
    }

    init(
        apiKey: String, ledger: EgressLedger, defaultModel: String = "gemini-2.5-flash",
        transport: any HTTPTransport
    ) {
        self.configuration = ProviderConfiguration(
            id: .google,
            displayName: "Google",
            baseURL: requiredURL("https://generativelanguage.googleapis.com/v1beta"),
            apiKey: apiKey,
            defaultModel: defaultModel,
            supportsTools: true,
            supportsVision: true,
            ledger: ledger,
            transport: transport
        )
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validateMedia(request, supportsVision: true)
                    let model = request.model.isEmpty ? configuration.defaultModel : request.model
                    var components = URLComponents(
                        url: configuration.baseURL
                            .appendingPathComponent("models")
                            .appendingPathComponent("\(model):streamGenerateContent"),
                        resolvingAgainstBaseURL: false
                    )
                    components?.queryItems = [
                        URLQueryItem(name: "alt", value: "sse"),
                        URLQueryItem(name: "key", value: configuration.apiKey),
                    ]
                    guard let url = components?.url else {
                        throw AIKitError.invalidResponse("Invalid Gemini URL")
                    }
                    let urlRequest = try jsonRequest(url: url, body: geminiRequestBody(request))
                    await record(request, configuration: configuration)
                    let (data, response) = try await configuration.transport.data(for: urlRequest)
                    try validate(response)
                    for chunk in try GeminiStreamParser.parse(data) { continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func validateMedia(_ request: ChatRequest, supportsVision: Bool) throws {
    if request.mediaAttached && (!supportsVision || !request.mediaConsent) {
        throw AIKitError.mediaConsentRequired
    }
}

private func requiredURL(_ value: String) -> URL {
    guard let url = URL(string: value) else {
        preconditionFailure("Invalid built-in provider URL: \(value)")
    }
    return url
}

private func record(_ request: ChatRequest, configuration: ProviderConfiguration) async {
    await configuration.ledger.record(
        EgressEntry(
            provider: configuration.id,
            model: request.model.isEmpty ? configuration.defaultModel : request.model,
            purpose: request.purpose,
            mediaAttached: request.mediaAttached
        ))
}

private func validate(_ response: HTTPURLResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
        throw AIKitError.requestFailed(response.statusCode)
    }
}

private func jsonRequest(url: URL, body: JSONValue) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(body)
    return request
}

private func messages(_ request: ChatRequest) -> JSONValue {
    .array(
        request.messages.map { message in
            .object(["role": .string(message.role.rawValue), "content": .string(message.content)])
        })
}

private func openAITools(_ tools: [ToolSchema]) -> JSONValue {
    .array(
        tools.map { tool in
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(tool.name), "description": .string(tool.description),
                    "parameters": tool.parameters,
                ]),
            ])
        })
}

private func openAIRequestBody(_ request: ChatRequest, supportsTools: Bool) -> JSONValue {
    var allMessages: [JSONValue] = [
        .object(["role": .string("system"), "content": .string(request.system)])
    ]
    if case .array(let following) = messages(request) { allMessages.append(contentsOf: following) }
    var body: [String: JSONValue] = [
        "model": .string(request.model), "stream": .bool(true),
        "messages": .array(allMessages), "max_tokens": .number(Double(request.maxTokens)),
        "stream_options": .object(["include_usage": .bool(true)]),
    ]
    if supportsTools && !request.tools.isEmpty { body["tools"] = openAITools(request.tools) }
    return .object(body)
}

private func anthropicRequestBody(_ request: ChatRequest) -> JSONValue {
    .object([
        "model": .string(request.model), "system": .string(request.system),
        "messages": messages(request), "max_tokens": .number(Double(request.maxTokens)),
        "stream": .bool(true),
        "tools": .array(
            request.tools.map { tool in
                .object([
                    "name": .string(tool.name), "description": .string(tool.description),
                    "input_schema": tool.parameters,
                ])
            }),
    ])
}

private func geminiRequestBody(_ request: ChatRequest) -> JSONValue {
    let declarations: JSONValue = .array(
        request.tools.map { tool in
            .object([
                "name": .string(tool.name), "description": .string(tool.description),
                "parameters": tool.parameters,
            ])
        })
    return .object([
        "systemInstruction": .object(["parts": .array([.object(["text": .string(request.system)])])]
        ),
        "contents": .array(
            request.messages.map { message in
                .object([
                    "role": .string(message.role == .assistant ? "model" : "user"),
                    "parts": .array([.object(["text": .string(message.content)])]),
                ])
            }),
        "tools": .array([.object(["functionDeclarations": declarations])]),
        "generationConfig": .object(["maxOutputTokens": .number(Double(request.maxTokens))]),
    ])
}

private enum SSE {
    static func payloads(_ data: Data) throws -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AIKitError.invalidResponse("SSE was not UTF-8")
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n").compactMap { event in
                let payload = event.split(whereSeparator: \.isNewline)
                    .filter { $0.hasPrefix("data:") }
                    .map { line in String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                guard !payload.isEmpty, payload != "[DONE]" else { return nil }
                return Data(payload.utf8)
            }
    }
}

enum OpenAIStreamParser {
    private struct Pending {
        var id = ""
        var name = ""
        var arguments = ""
    }

    static func parse(_ data: Data) throws -> [ChatChunk] {
        var output: [ChatChunk] = []
        var pending: [Int: Pending] = [:]
        var reason: StopReason = .complete
        for payload in try SSE.payloads(data) {
            guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: payload)
            else { continue }
            if case .object(let usage)? = root["usage"] {
                output.append(
                    .usage(
                        inputTokens: usage["prompt_tokens"]?.int ?? 0,
                        outputTokens: usage["completion_tokens"]?.int ?? 0
                    ))
            }
            guard case .array(let choices)? = root["choices"] else { continue }
            for choice in choices {
                guard case .object(let object) = choice else { continue }
                if let finish = object["finish_reason"]?.stringValue, finish == "tool_calls" {
                    reason = .toolUse
                }
                guard case .object(let delta)? = object["delta"] else { continue }
                if let text = delta["content"]?.stringValue, !text.isEmpty {
                    output.append(.text(text))
                }
                guard case .array(let calls)? = delta["tool_calls"] else { continue }
                for call in calls {
                    guard case .object(let callObject) = call else { continue }
                    let index = callObject["index"]?.int ?? 0
                    var value = pending[index] ?? Pending()
                    value.id += callObject["id"]?.stringValue ?? ""
                    if case .object(let function)? = callObject["function"] {
                        value.name += function["name"]?.stringValue ?? ""
                        value.arguments += function["arguments"]?.stringValue ?? ""
                    }
                    pending[index] = value
                }
            }
        }
        for index in pending.keys.sorted() {
            guard let call = pending[index] else { continue }
            let arguments = try decodeArguments(call.arguments)
            output.append(
                .toolCall(ToolInvocation(callID: call.id, name: call.name, arguments: arguments)))
        }
        output.append(.done(reason))
        return output
    }
}

enum AnthropicStreamParser {
    private struct Pending {
        var id: String
        var name: String
        var arguments = ""
    }

    static func parse(_ data: Data) throws -> [ChatChunk] {
        var output: [ChatChunk] = []
        var pending: [Int: Pending] = [:]
        var reason: StopReason = .complete
        for payload in try SSE.payloads(data) {
            guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: payload)
            else { continue }
            switch root["type"]?.stringValue {
            case "content_block_start":
                guard let index = root["index"]?.int,
                    case .object(let block)? = root["content_block"],
                    block["type"]?.stringValue == "tool_use"
                else { continue }
                pending[index] = Pending(
                    id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "")
            case "content_block_delta":
                guard let index = root["index"]?.int, case .object(let delta)? = root["delta"]
                else { continue }
                if let text = delta["text"]?.stringValue, !text.isEmpty {
                    output.append(.text(text))
                }
                if let fragment = delta["partial_json"]?.stringValue {
                    pending[index]?.arguments += fragment
                }
            case "content_block_stop":
                guard let index = root["index"]?.int, let call = pending.removeValue(forKey: index)
                else { continue }
                output.append(
                    .toolCall(
                        ToolInvocation(
                            callID: call.id, name: call.name,
                            arguments: try decodeArguments(call.arguments))))
            case "message_delta":
                if case .object(let delta)? = root["delta"],
                    delta["stop_reason"]?.stringValue == "tool_use"
                {
                    reason = .toolUse
                }
                if case .object(let usage)? = root["usage"] {
                    output.append(
                        .usage(inputTokens: 0, outputTokens: usage["output_tokens"]?.int ?? 0))
                }
            case "message_start":
                if case .object(let message)? = root["message"],
                    case .object(let usage)? = message["usage"]
                {
                    output.append(
                        .usage(inputTokens: usage["input_tokens"]?.int ?? 0, outputTokens: 0))
                }
            default: continue
            }
        }
        output.append(.done(reason))
        return output
    }
}

enum GeminiStreamParser {
    static func parse(_ data: Data) throws -> [ChatChunk] {
        var output: [ChatChunk] = []
        var counter = 0
        for payload in try SSE.payloads(data) {
            guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: payload)
            else { continue }
            if case .object(let usage)? = root["usageMetadata"] {
                output.append(
                    .usage(
                        inputTokens: usage["promptTokenCount"]?.int ?? 0,
                        outputTokens: usage["candidatesTokenCount"]?.int ?? 0
                    ))
            }
            guard case .array(let candidates)? = root["candidates"] else { continue }
            for candidate in candidates {
                guard case .object(let candidateObject) = candidate,
                    case .object(let content)? = candidateObject["content"],
                    case .array(let parts)? = content["parts"]
                else { continue }
                for part in parts {
                    guard case .object(let partObject) = part else { continue }
                    if let text = partObject["text"]?.stringValue { output.append(.text(text)) }
                    if case .object(let call)? = partObject["functionCall"],
                        let name = call["name"]?.stringValue
                    {
                        counter += 1
                        output.append(
                            .toolCall(
                                ToolInvocation(
                                    callID: "gemini-\(counter)", name: name,
                                    arguments: call["args"] ?? .object([:]))))
                    }
                }
            }
        }
        output.append(.done(output.containsToolCall ? .toolUse : .complete))
        return output
    }
}

private func decodeArguments(_ source: String) throws -> JSONValue {
    if source.isEmpty { return .object([:]) }
    do { return try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) } catch {
        throw AIKitError.invalidResponse("Tool arguments were not JSON")
    }
}

extension JSONValue {
    fileprivate var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }
    fileprivate var int: Int? { if case .number(let value) = self { Int(value) } else { nil } }
}

extension Array where Element == ChatChunk {
    fileprivate var containsToolCall: Bool {
        contains { if case .toolCall = $0 { true } else { false } }
    }
}
