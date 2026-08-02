import AIKit
import Foundation
import Observation

/// User-controlled provider, confirmation, credential, and egress settings.
@MainActor
@Observable
public final class AISettingsModel {
    public var selectedProvider: ProviderID = .openAICompatible
    public var model = "llama3.2"
    public var compatibleBaseURL = "http://localhost:11434/v1"
    public var confirmationPolicy: ConfirmationPolicy = .confirmDestructive
    public private(set) var configuredProviders: [ProviderID] = []
    public private(set) var egressEntries: [EgressEntry] = []
    public private(set) var notice: String?

    public let credentialStore: CredentialStore
    public let ledger: EgressLedger

    public init(libraryRoot: URL) {
        self.credentialStore = CredentialStore()
        self.ledger = EgressLedger(
            storageURL: libraryRoot.appendingPathComponent("EgressLedger.json"))
    }

    public func refresh() async {
        do {
            configuredProviders = try await credentialStore.configuredProviders()
            egressEntries = await ledger.entries()
            notice = nil
        } catch {
            notice = "Provider settings could not be refreshed."
        }
    }

    public func saveCredential(_ value: String, provider: ProviderID) async {
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try await credentialStore.delete(provider: provider)
            } else {
                try await credentialStore.store(trimmed, provider: provider)
            }
            await refresh()
            notice = trimmed.isEmpty ? "Credential removed." : "Credential saved in Keychain."
        } catch {
            notice = "The credential could not be saved in Keychain."
        }
    }

    public func provider() async throws -> any AIProvider {
        switch selectedProvider {
        case .openAICompatible:
            guard let url = URL(string: compatibleBaseURL),
                let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { throw AIKitError.invalidResponse("The compatible provider URL is invalid") }
            return OpenAICompatibleProvider(
                baseURL: url,
                defaultModel: model.isEmpty ? "local-model" : model,
                ledger: ledger
            )
        case .openAI:
            guard let key = try await credentialStore.key(for: .openAI), !key.isEmpty else {
                throw AIKitError.missingCredential(.openAI)
            }
            return OpenAIProvider(
                apiKey: key, ledger: ledger, defaultModel: model.isEmpty ? "gpt-5.6-sol" : model)
        case .anthropic:
            guard let key = try await credentialStore.key(for: .anthropic), !key.isEmpty else {
                throw AIKitError.missingCredential(.anthropic)
            }
            return AnthropicProvider(
                apiKey: key, ledger: ledger,
                defaultModel: model.isEmpty ? "claude-sonnet-4-6" : model)
        case .google:
            guard let key = try await credentialStore.key(for: .google), !key.isEmpty else {
                throw AIKitError.missingCredential(.google)
            }
            return GoogleProvider(
                apiKey: key, ledger: ledger,
                defaultModel: model.isEmpty ? "gemini-2.5-flash" : model)
        default:
            throw AIKitError.invalidResponse("Unsupported provider")
        }
    }
}
