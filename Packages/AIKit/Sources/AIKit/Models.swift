import CoreModel
import Foundation

/// A stable identifier for an AI provider and its credential.
public struct ProviderID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let anthropic: Self = "anthropic"
    public static let openAI: Self = "openai"
    public static let google: Self = "google"
    public static let openAICompatible: Self = "openai-compatible"
}

/// The portable interface implemented by every hosted or local model adapter.
public protocol AIProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var supportsTools: Bool { get }
    var supportsVision: Bool { get }
    var defaultModel: String { get }
    func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error>
}

/// One complete request sent to a provider.
public struct ChatRequest: Codable, Sendable, Equatable {
    public var model: String
    public var system: String
    public var messages: [ChatMessage]
    public var tools: [ToolSchema]
    public var maxTokens: Int
    public var purpose: EgressPurpose
    public var mediaAttached: Bool
    public var mediaConsent: Bool

    public init(
        model: String,
        system: String,
        messages: [ChatMessage],
        tools: [ToolSchema] = ToolCatalog.all,
        maxTokens: Int = 2_048,
        purpose: EgressPurpose = .chat,
        mediaAttached: Bool = false,
        mediaConsent: Bool = false
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.purpose = purpose
        self.mediaAttached = mediaAttached
        self.mediaConsent = mediaConsent
    }
}

/// A role/content pair in a provider-independent conversation.
public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: String
    public var role: Role
    public var content: String

    public init(id: String = UUID().uuidString, role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

/// Why a streamed response ended.
public enum StopReason: String, Codable, Sendable, Equatable {
    case complete
    case toolUse
    case maxTokens
    case cancelled
    case unknown
}

/// A normalized unit from a provider stream.
public enum ChatChunk: Sendable, Equatable {
    case text(String)
    case toolCall(ToolInvocation)
    case usage(inputTokens: Int, outputTokens: Int)
    case done(StopReason)
}

/// A single provider-requested tool call.
public struct ToolInvocation: Codable, Sendable, Equatable {
    public var callID: String
    public var name: String
    public var arguments: JSONValue

    public init(callID: String, name: String, arguments: JSONValue) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

/// Whether a tool only reads, produces an undoable patch, or affects external state.
public enum ToolKind: String, Codable, Sendable, Equatable { case read, write, confirm }

/// A JSON-schema tool declaration understood by all adapters.
public struct ToolSchema: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var kind: ToolKind
    public var parameters: JSONValue

    public init(name: String, description: String, kind: ToolKind, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.kind = kind
        self.parameters = parameters
    }
}

/// Controls when undoable assistant edits require review.
public enum ConfirmationPolicy: String, Codable, Sendable, CaseIterable {
    case autoApply
    case confirmDestructive
    case confirmAll

    public func requiresConfirmation(for kind: ToolKind) -> Bool {
        if kind == .confirm { return true }
        switch self {
        case .autoApply: return false
        case .confirmDestructive: return kind == .write
        case .confirmAll: return kind != .read
        }
    }
}

/// The App layer's normalized result after resolving a tool invocation.
public struct ToolResult: Sendable, Equatable {
    public var callID: String
    public var message: String
    public var patch: GraphPatch?
    public var requiresConfirmation: Bool

    public init(
        callID: String,
        message: String,
        patch: GraphPatch? = nil,
        requiresConfirmation: Bool = false
    ) {
        self.callID = callID
        self.message = message
        self.patch = patch
        self.requiresConfirmation = requiresConfirmation
    }
}

/// A compact, provider-safe view of one timeline item.
public struct ContextItem: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var duration: Double
    public var hasAudio: Bool
    public var clicks: Int
    public var effects: [String]
    public var alignment: String

    public init(
        id: String,
        name: String,
        duration: Double,
        hasAudio: Bool,
        clicks: Int,
        effects: [String],
        alignment: String
    ) {
        self.id = id
        self.name = name
        self.duration = duration
        self.hasAudio = hasAudio
        self.clicks = clicks
        self.effects = effects
        self.alignment = alignment
    }
}

/// The bounded timeline context supplied to a model instead of a full document.
public struct ContextDigest: Codable, Sendable, Equatable {
    public static let itemLimit = 40
    public var projectName: String
    public var duration: Double
    public var canvas: String
    public var selectedItemID: String?
    public var items: [ContextItem]
    public var omittedItemCount: Int

    public init(
        projectName: String,
        duration: Double,
        canvas: String,
        selectedItemID: String?,
        items: [ContextItem]
    ) {
        self.projectName = projectName
        self.duration = duration
        self.canvas = canvas
        self.selectedItemID = selectedItemID
        self.items = Array(items.prefix(Self.itemLimit))
        self.omittedItemCount = max(0, items.count - Self.itemLimit)
    }

    public func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let result = String(data: data, encoding: .utf8) else {
            throw AIKitError.invalidResponse("Context digest is not UTF-8")
        }
        return result
    }
}

/// Failures common to the provider and on-device AI boundary.
public enum AIKitError: Error, Sendable, Equatable, LocalizedError {
    case missingCredential(ProviderID)
    case invalidResponse(String)
    case requestFailed(Int)
    case mediaConsentRequired
    case transcriptionUnavailable
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            return "No credential is configured for \(provider.rawValue)."
        case .invalidResponse(let reason): return "The provider response was invalid: \(reason)"
        case .requestFailed(let status): return "The provider request failed with HTTP \(status)."
        case .mediaConsentRequired: return "Attaching media requires explicit consent."
        case .transcriptionUnavailable:
            return "On-device transcription is unavailable for this locale."
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        }
    }
}
