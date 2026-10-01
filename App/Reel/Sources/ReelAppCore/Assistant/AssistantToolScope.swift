import AIKit

/// Which on-demand command categories an assistant turn is offered directly,
/// rather than left behind meta-tool discovery.
enum AssistantToolScope {
    /// Every editing category, not just the open workspace's. Discovery costs a
    /// round trip and asks the model to guess at a name it was never shown, and
    /// a request that spans workspaces — redact this photo, then put it on the
    /// timeline — needs both sets at once.
    static let everyWorkspace: Set<CommandCategory> = [
        .clip, .effect, .audio, .timeline, .pdf, .image, .text, .asset, .file,
    ]

    /// - Parameter isLocalModel: Whether the turn goes to a model on this Mac.
    ///   Those are small and run in a context window measured in a few thousand
    ///   tokens. Every workspace's schemas together fill most of it and leave no
    ///   room for tool results, so a local model gets the open workspace only
    ///   and reaches the rest through `listCommands` and `runCommand`.
    static func categories(
        for document: AssistantSessionToken.Document,
        isLocalModel: Bool
    ) -> Set<CommandCategory> {
        guard isLocalModel else { return everyWorkspace }
        switch document {
        case .timeline: return [.clip, .effect, .audio, .timeline]
        case .text: return [.text]
        case .pdf: return [.pdf]
        case .image: return [.image]
        }
    }
}
