import Foundation

/// Asks a local Ollama what it has, what those models can do, and installs more.
protocol LocalModelServing: Sendable {
    func installedModels(nativeBaseURL: URL) async throws -> [String]
    func capabilities(of model: String, nativeBaseURL: URL) async -> LocalModelCapabilities
    func unload(_ model: String, nativeBaseURL: URL) async
    func pull(
        _ model: String,
        nativeBaseURL: URL
    ) -> AsyncThrowingStream<LocalModelPullEvent, any Error>
}

struct OllamaModelService: LocalModelServing {
    private struct InstalledList: Decodable {
        struct Model: Decodable { var name: String }
        var models: [Model]
    }

    private struct ShowResponse: Decodable {
        var capabilities: [String]?
    }

    /// Reads one model's capabilities, or falls back when the server cannot say.
    ///
    /// Never throws. A server that does not answer `/api/show` is not an error
    /// worth failing an assistant turn over — it just means clipx keeps the
    /// behaviour it had before it could ask.
    func capabilities(of model: String, nativeBaseURL: URL) async -> LocalModelCapabilities {
        var request = URLRequest(url: nativeBaseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        guard
            let body = try? JSONSerialization.data(withJSONObject: ["model": model])
        else { return .unreported }
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let shown = try? JSONDecoder().decode(ShowResponse.self, from: data),
            let reported = shown.capabilities
        else { return .unreported }
        return LocalModelCapabilities(reported: reported)
    }

    func installedModels(nativeBaseURL: URL) async throws -> [String] {
        var request = URLRequest(url: nativeBaseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let list = try JSONDecoder().decode(InstalledList.self, from: data)
        return list.models.map(\.name).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Drops a model from memory now instead of after Ollama's idle timeout.
    ///
    /// Ollama keeps a model resident for five minutes after the last request,
    /// which on a 16 GB machine is several gigabytes still held by a server the
    /// person may think they finished with when they quit clipx. A generate
    /// request with `keep_alive: 0` unloads it immediately.
    ///
    /// Never throws: this runs while the app is going away, and there is nothing
    /// useful to do about a failure at that point.
    func unload(_ model: String, nativeBaseURL: URL) async {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var request = URLRequest(url: nativeBaseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 2
        guard
            let body = try? JSONSerialization.data(
                withJSONObject: ["model": name, "keep_alive": 0])
        else { return }
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    func pull(
        _ model: String,
        nativeBaseURL: URL
    ) -> AsyncThrowingStream<LocalModelPullEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: nativeBaseURL.appendingPathComponent("api/pull"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: ["model": model, "stream": true]
                    )
                    // Applies between chunks, not to the whole transfer: a pull
                    // runs for many minutes but reports progress continuously,
                    // so a stalled connection still gives up rather than hanging.
                    request.timeoutInterval = 60

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        continuation.yield(
                            .failed("Ollama responded with HTTP \(status).")
                        )
                        continuation.finish()
                        return
                    }
                    for try await line in bytes.lines {
                        guard let event = LocalModelPullEvent(line: line) else { continue }
                        continuation.yield(event)
                        if event == .finished { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
