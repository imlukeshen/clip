import Foundation

/// An image attached to a chat message.
///
/// Held as encoded bytes and a media type rather than a platform image, so AIKit
/// stays free of AppKit and each provider adapter can emit the shape its API
/// expects. They differ: OpenAI-compatible servers take a `data:` URL,
/// Anthropic takes base64 under a `source` object, Gemini takes `inline_data`,
/// and Ollama's native endpoint takes bare base64 beside the text. Sending one
/// provider's shape to another is accepted as valid JSON and then silently
/// ignored, so the conversions are kept together here.
public struct ChatImage: Codable, Sendable, Equatable {
    /// An IANA media type such as `image/png`.
    public let mediaType: String
    public let data: Data

    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }

    /// PNG bytes, the format the window renderer produces.
    public static func png(_ data: Data) -> ChatImage {
        ChatImage(mediaType: "image/png", data: data)
    }

    public var base64: String { data.base64EncodedString() }

    /// The inline form OpenAI-compatible servers accept in an `image_url` part.
    public var dataURL: String { "data:\(mediaType);base64,\(base64)" }
}
