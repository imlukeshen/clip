import Foundation

protocol CompatibleProviderPreflighting: Sendable {
    func check(baseURL: URL, model: String) async throws
}

protocol LocalModelHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionLocalModelTransport: LocalModelHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CompatibleProviderSetupError.invalidModelList
        }
        return (data, response)
    }
}

enum CompatibleProviderSetupError: Error, Sendable, Equatable, LocalizedError {
    case insecureRemoteURL
    case unavailable(isOllama: Bool, model: String)
    case failed(status: Int, isOllama: Bool)
    case modelMissing(String, isOllama: Bool)
    case invalidModelList

    var errorDescription: String? {
        switch self {
        case .insecureRemoteURL:
            return "Use HTTPS for remote compatible providers. HTTP is allowed only for localhost."
        case .unavailable(true, let model):
            return
                "Ollama is not reachable at localhost:11434. Start Ollama, then run `ollama pull \(model)` if the model is not installed."
        case .unavailable(false, _):
            return
                "The compatible provider is not reachable. Start the server and verify its Base URL."
        case .failed(let status, true):
            return
                "Ollama responded with HTTP \(status). Restart Ollama and verify its OpenAI-compatible endpoint."
        case .failed(let status, false):
            return
                "The compatible provider model check failed with HTTP \(status). Verify its Base URL."
        case .modelMissing(let model, true):
            return
                "Ollama is running, but `\(model)` is not installed. Run `ollama pull \(model)`, then try again."
        case .modelMissing(let model, false):
            return
                "The compatible provider does not list `\(model)`. Choose an installed model and try again."
        case .invalidModelList:
            return "The compatible provider did not return a valid OpenAI-compatible model list."
        }
    }
}

struct CompatibleProviderPreflight: CompatibleProviderPreflighting {
    private struct ModelList: Decodable {
        struct Model: Decodable { var id: String }
        var data: [Model]
    }

    private let transport: any LocalModelHTTPTransport

    init(transport: any LocalModelHTTPTransport = URLSessionLocalModelTransport()) {
        self.transport = transport
    }

    func check(baseURL: URL, model: String) async throws {
        let isOllama = Self.isDefaultOllama(baseURL)
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CompatibleProviderSetupError.unavailable(
                isOllama: isOllama,
                model: model
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CompatibleProviderSetupError.failed(
                status: response.statusCode,
                isOllama: isOllama
            )
        }
        guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw CompatibleProviderSetupError.invalidModelList
        }
        let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = Set(list.data.map(\.id))
        guard available.contains(requested) || available.contains("\(requested):latest") else {
            throw CompatibleProviderSetupError.modelMissing(requested, isOllama: isOllama)
        }
    }

    private static func isDefaultOllama(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        return isLoopback && (url.port ?? 80) == 11_434
    }
}
