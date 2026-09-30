import Foundation

/// What a local model is for in clipx.
public enum LocalModelRole: String, Codable, Sendable, Equatable, CaseIterable {
    /// Emits the tool calls that actually change the document.
    case editing
    /// Reads the picture of the window and says what is in it.
    case vision
}

/// A local model clipx offers to install for the assistant.
///
/// Each entry carries the role it can fill, because locally the two barely
/// overlap. A model that reads images generally cannot emit tool calls, and
/// sending tool schemas to one is answered by Ollama with HTTP 400 rather than a
/// degraded reply — so the pair is chosen by role rather than hoping for one
/// model that does both. The list is a starting point, not a catalogue; any
/// other Ollama model can still be installed by typing its name.
public struct LocalModelSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { name }
    /// The name Ollama installs by, exactly as `ollama pull` takes it.
    public let name: String
    public let role: LocalModelRole
    /// Roughly what the download costs in gigabytes.
    ///
    /// Approximate on purpose: Ollama re-quantises and re-tags models, so a
    /// figure pinned here would drift. It is here to set expectations before
    /// someone starts a multi-gigabyte download, and the real total replaces it
    /// as soon as the transfer reports one.
    public let approximateGigabytes: Double
    public let summary: String

    public init(
        name: String,
        role: LocalModelRole,
        approximateGigabytes: Double,
        summary: String
    ) {
        self.name = name
        self.role = role
        self.approximateGigabytes = approximateGigabytes
        self.summary = summary
    }

    /// The suggestions offered in Settings, smallest first within each role.
    public static let catalog: [LocalModelSuggestion] = [
        LocalModelSuggestion(
            name: "qwen3:4b",
            role: .editing,
            approximateGigabytes: 2.6,
            summary: "Smallest one worth trying. Comfortable on 16 GB."
        ),
        LocalModelSuggestion(
            name: "llama3.1:8b",
            role: .editing,
            approximateGigabytes: 4.9,
            summary: "Long-established tool calling. A good baseline."
        ),
        LocalModelSuggestion(
            name: "qwen3:8b",
            role: .editing,
            approximateGigabytes: 5.2,
            summary: "Stronger at multi-step edits than the 4B."
        ),
        LocalModelSuggestion(
            name: "mistral-nemo",
            role: .editing,
            approximateGigabytes: 7.1,
            summary: "12B. Wants 32 GB to stay responsive."
        ),
        LocalModelSuggestion(
            name: "llava:7b",
            role: .vision,
            approximateGigabytes: 4.1,
            summary: "Reads the window. Embellishes; it is a 7B."
        ),
        LocalModelSuggestion(
            name: "llama3.2-vision:11b",
            role: .vision,
            approximateGigabytes: 7.9,
            summary: "Better at reading UI text. Wants 32 GB alongside an editor."
        ),
    ]

    public static func catalog(for role: LocalModelRole) -> [LocalModelSuggestion] {
        catalog.filter { $0.role == role }
    }
}

/// A pair of local models that together cover what one cannot.
///
/// Offered because the capability clipx needs — read the window *and* call tools
/// — does not exist in one model that fits an ordinary Mac. Installing both and
/// routing between them is the working substitute.
public struct LocalModelPairing: Identifiable, Equatable, Sendable {
    public var id: String { "\(editing)+\(vision)" }
    public let title: String
    public let editing: String
    public let vision: String
    public let summary: String

    public var models: [String] { [editing, vision] }

    public var approximateGigabytes: Double {
        LocalModelSuggestion.catalog
            .filter { models.contains($0.name) }
            .reduce(0) { $0 + $1.approximateGigabytes }
    }

    public static let catalog: [LocalModelPairing] = [
        LocalModelPairing(
            title: "See and edit (16 GB)",
            editing: "qwen3:4b",
            vision: "llava:7b",
            summary: "The smallest pair that covers both roles."
        ),
        LocalModelPairing(
            title: "See and edit (32 GB)",
            editing: "qwen3:8b",
            vision: "llama3.2-vision:11b",
            summary: "Better at both, but needs the memory."
        ),
    ]
}
