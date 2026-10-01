import CoreModel
import Foundation

/// Reads Ollama's native chat stream: one JSON object per line.
enum OllamaStreamParser {
    static func parse(_ data: Data) throws -> [ChatChunk] {
        var output: [ChatChunk] = []
        var reason: StopReason = .complete
        var callCount = 0
        // Split on the byte, not on characters: a JSON string may legally hold
        // an unescaped Unicode line separator, which is not the end of a line.
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: line)
            else { continue }
            if let message = root["error"]?.stringValue {
                throw AIKitError.invalidResponse(message)
            }
            if case .object(let message)? = root["message"] {
                // `thinking` is the model's reasoning, streamed separately from
                // its answer. It is not part of the reply, so it is not read.
                if let text = message["content"]?.stringValue, !text.isEmpty {
                    output.append(.text(text))
                }
                if case .array(let calls)? = message["tool_calls"] {
                    for call in calls {
                        guard case .object(let function)? = call["function"],
                            let name = function["name"]?.stringValue, !name.isEmpty
                        else { continue }
                        callCount += 1
                        // Older servers send no ID. Results are matched to
                        // calls by ID, so each still needs its own.
                        let id = call["id"]?.stringValue ?? ""
                        output.append(
                            .toolCall(
                                ToolInvocation(
                                    callID: id.isEmpty ? "ollama-\(callCount)" : id,
                                    name: name,
                                    arguments: try arguments(function["arguments"]))))
                    }
                }
            }
            if root["done"] == .bool(true) {
                output.append(
                    .usage(
                        inputTokens: root["prompt_eval_count"]?.int ?? 0,
                        outputTokens: root["eval_count"]?.int ?? 0
                    ))
                if root["done_reason"]?.stringValue == "length" { reason = .maxTokens }
            }
        }
        if callCount > 0 { reason = .toolUse }
        output.append(.done(reason))
        return output
    }

    /// Arguments arrive as an object; some versions sent them as a JSON string.
    private static func arguments(_ value: JSONValue?) throws -> JSONValue {
        switch value {
        case .object: return value ?? .object([:])
        case .string(let source): return try decodeArguments(source)
        default: return .object([:])
        }
    }
}
