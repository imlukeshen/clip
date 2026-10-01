import CoreModel
import Foundation
import Testing

@testable import AIKit

@Suite("Chat image encoding")
struct ChatImageEncodingTests {
    private let pixel = ChatImage.png(Data([0x89, 0x50, 0x4E, 0x47]))

    @Test("A request reports attached media without being told")
    func mediaAttachedIsDerived() {
        let text = ChatRequest(
            model: "m", system: "s", messages: [.init(role: .user, content: "hi")])
        #expect(!text.mediaAttached)

        let withImage = ChatRequest(
            model: "m",
            system: "s",
            messages: [.init(role: .user, content: "what is this", images: [pixel])]
        )
        // Derived, so a caller cannot attach an image and still tell the consent
        // gate and the egress ledger that nothing was sent.
        #expect(withImage.mediaAttached)
    }

    @Test("An image without consent is refused before any request is built")
    func consentGate() {
        let request = ChatRequest(
            model: "m",
            system: "s",
            messages: [.init(role: .user, content: "look", images: [pixel])],
            mediaConsent: false
        )
        #expect(throws: AIKitError.mediaConsentRequired) {
            try validateMedia(request, supportsVision: true)
        }
        #expect(throws: AIKitError.mediaConsentRequired) {
            try validateMedia(request, supportsVision: false)
        }
    }

    @Test("A vision-less provider refuses images even with consent")
    func visionRequired() {
        let request = ChatRequest(
            model: "m",
            system: "s",
            messages: [.init(role: .user, content: "look", images: [pixel])],
            mediaConsent: true
        )
        #expect(throws: AIKitError.mediaConsentRequired) {
            try validateMedia(request, supportsVision: false)
        }
        #expect(throws: Never.self) { try validateMedia(request, supportsVision: true) }
    }

    @Test("OpenAI-compatible servers get a data URL in an image_url part")
    func openAIShape() throws {
        let body = try openAIRequestBody(requestWithImage(), supportsTools: false)
        let parts = try #require(array(lastMessage(in: body, key: "messages")?["content"]))
        #expect(parts.count == 2)
        #expect(text(parts.first?["type"]) == "text")
        #expect(text(parts.last?["type"]) == "image_url")
        let url = try #require(text(parts.last?["image_url"]?["url"]))
        #expect(url.hasPrefix("data:image/png;base64,"))
    }

    @Test("A message with no image keeps plain string content")
    func openAIKeepsPlainText() throws {
        let request = ChatRequest(
            model: "m", system: "s", messages: [.init(role: .user, content: "hello")])
        let body = try openAIRequestBody(request, supportsTools: false)
        // Some compatible servers reject the array form when no image is
        // present, so the plain form has to survive.
        #expect(text(lastMessage(in: body, key: "messages")?["content"]) == "hello")
    }

    @Test("Anthropic gets base64 under a source object, not a data URL")
    func anthropicShape() throws {
        let body = anthropicRequestBody(requestWithImage())
        let blocks = try #require(array(lastMessage(in: body, key: "messages")?["content"]))
        let image = try #require(blocks.last)
        #expect(text(image["type"]) == "image")
        #expect(text(image["source"]?["type"]) == "base64")
        #expect(text(image["source"]?["media_type"]) == "image/png")
        // Bare base64: a data: URL here is accepted as JSON and then ignored.
        #expect(text(image["source"]?["data"]) == pixel.base64)
    }

    @Test("Gemini gets inline_data with a mime_type")
    func geminiShape() throws {
        let body = geminiRequestBody(requestWithImage())
        let contents = try #require(array(body["contents"]))
        let parts = try #require(array(contents.last?["parts"]))
        let inline = try #require(parts.last?["inline_data"])
        #expect(text(inline["mime_type"]) == "image/png")
        #expect(text(inline["data"]) == pixel.base64)
    }

    private func requestWithImage() -> ChatRequest {
        ChatRequest(
            model: "m",
            system: "s",
            messages: [.init(role: .user, content: "what is on screen", images: [pixel])],
            tools: [],
            mediaConsent: true
        )
    }

    private func lastMessage(in body: JSONValue, key: String) -> JSONValue? {
        array(body[key])?.last
    }

    private func array(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let values)? = value else { return nil }
        return values
    }

    private func text(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }
}
