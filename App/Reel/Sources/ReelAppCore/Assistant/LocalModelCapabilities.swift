import Foundation

/// What a local model can actually do, as its own server reports it.
///
/// clipx used to assume every compatible server could take tool schemas and let
/// the opt-in toggle decide whether it could take images. Both assumptions fail
/// loudly rather than quietly: Ollama answers a request carrying tools for a
/// model without them with `does not support tools` and HTTP 400, so selecting a
/// vision model broke every assistant turn, not just the ones with a picture.
public struct LocalModelCapabilities: Equatable, Sendable {
    public let tools: Bool
    public let vision: Bool

    public init(tools: Bool, vision: Bool) {
        self.tools = tools
        self.vision = vision
    }

    /// What to assume when the server does not report capabilities.
    ///
    /// Only Ollama answers `/api/show`. LM Studio, llama.cpp and the rest are
    /// reached through the compatible endpoint alone, so they keep the behaviour
    /// clipx had before detection existed rather than losing tool calling to a
    /// probe that was never going to succeed.
    public static let unreported = LocalModelCapabilities(tools: true, vision: false)

    /// Reads Ollama's `capabilities` array.
    public init(reported: [String]) {
        let values = Set(reported.map { $0.lowercased() })
        self.tools = values.contains("tools")
        self.vision = values.contains("vision")
    }
}
