import Foundation

/// A local model clipx offers to install for the assistant.
///
/// Every entry is one that advertises tool calling. That is the whole point: the
/// assistant drives clipx by emitting tool calls, so a model without it can hold
/// a conversation but cannot trim a clip, redact a region, or rename a file. The
/// list is deliberately short — it is a starting point, not a catalogue — and
/// any other Ollama model can still be installed by typing its name.
public struct LocalModelSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { name }
    /// The name Ollama installs by, exactly as `ollama pull` takes it.
    public let name: String
    /// Roughly what the download costs in gigabytes.
    ///
    /// Approximate on purpose: Ollama re-quantises and re-tags models, so a
    /// figure pinned here would drift. It is here to set expectations before
    /// someone starts a multi-gigabyte download, and the real total replaces it
    /// as soon as the transfer reports one.
    public let approximateGigabytes: Double
    public let summary: String

    public init(name: String, approximateGigabytes: Double, summary: String) {
        self.name = name
        self.approximateGigabytes = approximateGigabytes
        self.summary = summary
    }

    /// The suggestions offered in Settings, smallest first.
    public static let catalog: [LocalModelSuggestion] = [
        LocalModelSuggestion(
            name: "qwen3:4b",
            approximateGigabytes: 2.6,
            summary: "Smallest one worth trying. Runs on 16 GB of memory."
        ),
        LocalModelSuggestion(
            name: "llama3.1:8b",
            approximateGigabytes: 4.9,
            summary: "Long-established tool calling. A good baseline."
        ),
        LocalModelSuggestion(
            name: "qwen3:8b",
            approximateGigabytes: 5.2,
            summary: "Stronger at multi-step edits than the 4B."
        ),
        LocalModelSuggestion(
            name: "mistral-nemo",
            approximateGigabytes: 7.1,
            summary: "12B. Needs 32 GB to stay responsive."
        ),
    ]
}
