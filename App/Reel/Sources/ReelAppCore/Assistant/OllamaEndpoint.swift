import Foundation

/// Where Ollama's own API lives relative to the OpenAI-compatible one.
///
/// The assistant talks to `/v1`, which is the compatible surface every local
/// server exposes. Installing a model is not part of that surface, so it goes to
/// Ollama's native API at the same host — and only there, since LM Studio and
/// other compatible servers have no equivalent and manage models themselves.
public enum OllamaEndpoint {
    /// Ollama's default port. Anything else is treated as a different server.
    static let defaultPort = 11_434

    /// Whether this compatible base URL is a local Ollama.
    ///
    /// Model installation writes gigabytes to disk and reaches the network on
    /// the person's behalf, so it is offered only for a loopback server on
    /// Ollama's own port rather than for any host that happens to answer.
    public static func isLocalOllama(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        return isLoopback && (url.port ?? 80) == defaultPort
    }

    /// The native API root for a compatible base URL, dropping its `/v1` suffix.
    public static func nativeBaseURL(forCompatible url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var path = components.path
        if path.hasSuffix("/") { path = String(path.dropLast()) }
        if path.lowercased().hasSuffix("/v1") { path = String(path.dropLast(3)) }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}
