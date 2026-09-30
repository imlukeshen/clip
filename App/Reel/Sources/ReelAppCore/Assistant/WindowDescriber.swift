import AIKit
import Foundation
import OSLog

/// Turns a picture of clipx's window into text a non-seeing model can use.
///
/// Locally the capability clipx wants does not exist in one model: the ones that
/// read images cannot emit tool calls, and Ollama answers a request carrying
/// tool schemas for such a model with HTTP 400. So the two are run in turn — the
/// vision model says what is on screen, and its answer is handed to the editing
/// model as context. The editing model still makes every decision and every tool
/// call; this only gives it eyes.
public struct WindowDescriber: Sendable {
    /// What the vision model is asked. Deliberately narrow: a description that
    /// wanders into advice is worse than none, because the editing model cannot
    /// tell the difference between what was seen and what was suggested.
    static let prompt = """
        Describe what is visible in this screenshot of a macOS app, factually and \
        in at most six sentences. Name the panels, any selected or highlighted item, \
        and any text you can read clearly. Do not suggest actions and do not guess \
        at anything you cannot see.
        """

    private static let log = Logger(subsystem: "app.reel.editor", category: "assistant")

    public init() {}

    /// Returns a description, or nil when the vision model cannot be reached.
    ///
    /// Never throws. Failing to see is a reason to answer without eyes, not a
    /// reason to fail the turn the person actually asked for.
    public func describe(_ frame: ChatImage, using provider: any AIProvider) async -> String? {
        let request = ChatRequest(
            model: provider.defaultModel,
            system: "You describe user interface screenshots precisely and briefly.",
            messages: [.init(role: .user, content: Self.prompt, images: [frame])],
            tools: [],
            maxTokens: 400,
            purpose: .chat,
            mediaConsent: true
        )
        var text = ""
        do {
            for try await chunk in provider.send(request) {
                if case .text(let value) = chunk { text += value }
            }
        } catch {
            Self.log.error("The vision model could not describe the window")
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
