import CoreModel
import Foundation

/// An adapter for Ollama's native chat endpoint.
///
/// Ollama also serves the OpenAI-compatible surface, but that surface has no
/// field for the context window, so every request runs at the server's default.
/// On a 16 GB Mac the default is 4,096 tokens, which is less than clipx's prompt
/// once the tool schemas are in it, and Ollama answers an oversized prompt by
/// dropping part of it rather than failing. The model then works from a
/// fraction of its instructions and nothing in the reply says so. The native
/// endpoint takes `num_ctx` on each request.
public struct OllamaChatProvider: AIProvider {
    /// The context window requested when the caller does not choose one.
    ///
    /// Large enough for the system prompt, the tool schemas, the reply budget,
    /// and a few rounds of tool results. Not larger, because Ollama allocates
    /// the window up front: with a 4B model each further 4,096 tokens holds
    /// roughly another gigabyte of memory.
    public static let defaultContextLength = 8_192

    private let configuration: ProviderConfiguration
    private let contextLength: Int
    /// Reported as the compatible provider, because that is what the person
    /// selected in Settings and what the egress ledger should attribute to.
    public var id: ProviderID { configuration.id }
    public var displayName: String { configuration.displayName }
    public var supportsTools: Bool { configuration.supportsTools }
    public var supportsVision: Bool { configuration.supportsVision }
    public var defaultModel: String { configuration.defaultModel }

    /// - Parameter baseURL: Ollama's native root, without the `/v1` suffix the
    ///   compatible surface lives under.
    public init(
        baseURL: URL,
        defaultModel: String,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        contextLength: Int = OllamaChatProvider.defaultContextLength,
        ledger: EgressLedger
    ) {
        self.init(
            baseURL: baseURL,
            defaultModel: defaultModel,
            supportsTools: supportsTools,
            supportsVision: supportsVision,
            contextLength: contextLength,
            ledger: ledger,
            transport: URLSessionTransport()
        )
    }

    init(
        baseURL: URL,
        defaultModel: String,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        contextLength: Int = OllamaChatProvider.defaultContextLength,
        ledger: EgressLedger,
        transport: any HTTPTransport
    ) {
        self.configuration = ProviderConfiguration(
            id: .openAICompatible,
            displayName: "Ollama",
            baseURL: baseURL,
            apiKey: nil,
            defaultModel: defaultModel,
            supportsTools: supportsTools,
            supportsVision: supportsVision,
            ledger: ledger,
            transport: transport
        )
        self.contextLength = contextLength
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let configuration = self.configuration
        let contextLength = self.contextLength
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validateMedia(request, supportsVision: configuration.supportsVision)
                    let body = ollamaRequestBody(
                        request,
                        supportsTools: configuration.supportsTools,
                        contextLength: contextLength
                    )
                    var urlRequest = try jsonRequest(
                        url: configuration.baseURL.appendingPathComponent("api/chat"), body: body)
                    // The native stream is newline-delimited JSON, not SSE.
                    urlRequest.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                    await record(request, configuration: configuration)
                    let (data, response) = try await configuration.transport.data(for: urlRequest)
                    try validate(response)
                    for chunk in try OllamaStreamParser.parse(data) { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A request in Ollama's native shape.
///
/// Tool schemas match the compatible surface. Images do not: they are bare
/// base64 strings beside the text rather than `image_url` parts.
func ollamaRequestBody(
    _ request: ChatRequest,
    supportsTools: Bool,
    contextLength: Int
) -> JSONValue {
    var allMessages: [JSONValue] = [
        .object(["role": .string("system"), "content": .string(request.system)])
    ]
    for message in request.messages {
        var object: [String: JSONValue] = [
            "role": .string(message.role.rawValue), "content": .string(message.content),
        ]
        if !message.images.isEmpty {
            object["images"] = .array(message.images.map { .string($0.base64) })
        }
        allMessages.append(.object(object))
    }
    var body: [String: JSONValue] = [
        "model": .string(request.model), "stream": .bool(true),
        "messages": .array(allMessages),
        "options": .object([
            "num_ctx": .number(Double(contextLength)),
            "num_predict": .number(Double(request.maxTokens)),
        ]),
    ]
    if supportsTools && !request.tools.isEmpty { body["tools"] = openAITools(request.tools) }
    return .object(body)
}
