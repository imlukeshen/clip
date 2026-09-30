import Foundation

/// Lists and installs local models through Ollama's native API.
protocol LocalModelInstalling: Sendable {
    func installedModels(nativeBaseURL: URL) async throws -> [String]
    func pull(
        _ model: String,
        nativeBaseURL: URL
    ) -> AsyncThrowingStream<LocalModelPullEvent, any Error>
}

struct OllamaModelInstaller: LocalModelInstalling {
    private struct InstalledList: Decodable {
        struct Model: Decodable { var name: String }
        var models: [Model]
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
