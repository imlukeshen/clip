import AIKit
import Foundation
import Observation

/// User-controlled provider, confirmation, credential, and egress settings.
@MainActor
@Observable
public final class AISettingsModel {
    public private(set) var selectedProvider: ProviderID
    public var model: String {
        didSet {
            guard !isRestoringProvider else { return }
            defaults.set(model, forKey: Self.modelPreferenceKey(for: selectedProvider))
        }
    }
    public var compatibleBaseURL: String {
        didSet {
            guard Self.isSafePersistableBaseURL(compatibleBaseURL) else { return }
            defaults.set(compatibleBaseURL, forKey: Self.compatibleBaseURLPreferenceKey)
        }
    }
    public var confirmationPolicy: ConfirmationPolicy {
        didSet { defaults.set(confirmationPolicy.rawValue, forKey: Self.confirmationPreferenceKey) }
    }
    public private(set) var configuredProviders: [ProviderID] = []
    public private(set) var egressEntries: [EgressEntry] = []
    public private(set) var notice: String?
    public private(set) var isCheckingCompatibleProvider = false

    public let credentialStore: CredentialStore
    public let ledger: EgressLedger
    private let defaults: UserDefaults
    private let compatiblePreflight: any CompatibleProviderPreflighting
    private var isRestoringProvider = false

    public convenience init(libraryRoot: URL) {
        self.init(
            libraryRoot: libraryRoot,
            defaults: .standard,
            credentialStore: CredentialStore(),
            compatiblePreflight: CompatibleProviderPreflight()
        )
    }

    init(
        libraryRoot: URL,
        defaults: UserDefaults,
        credentialStore: CredentialStore,
        compatiblePreflight: any CompatibleProviderPreflighting
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.compatiblePreflight = compatiblePreflight
        self.ledger = EgressLedger(
            storageURL: libraryRoot.appendingPathComponent("EgressLedger.json"))
        let restoredProvider =
            defaults.string(forKey: Self.providerPreferenceKey)
            .map(ProviderID.init(rawValue:))
            .flatMap { Self.supportedProviders.contains($0) ? $0 : nil }
            ?? .openAICompatible
        self.selectedProvider = restoredProvider
        self.model = Self.restoredModel(for: restoredProvider, defaults: defaults)
        self.compatibleBaseURL =
            defaults.string(forKey: Self.compatibleBaseURLPreferenceKey)
            ?? Self.defaultCompatibleBaseURL
        self.confirmationPolicy =
            defaults.string(forKey: Self.confirmationPreferenceKey)
            .flatMap(ConfirmationPolicy.init(rawValue:))
            ?? .confirmDestructive
    }

    public func selectProvider(_ provider: ProviderID) {
        guard Self.supportedProviders.contains(provider), provider != selectedProvider else {
            return
        }
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: Self.providerPreferenceKey)
        isRestoringProvider = true
        model = Self.restoredModel(for: provider, defaults: defaults)
        isRestoringProvider = false
        notice = nil
    }

    /// Whether the configured connection target is a loopback host.
    public var usesLoopbackAssistantEndpoint: Bool {
        guard selectedProvider == .openAICompatible,
            let host = URLComponents(string: compatibleBaseURL)?.host?.lowercased()
        else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
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

    @discardableResult
    public func saveCredential(_ value: String, provider: ProviderID) async -> Bool {
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try await credentialStore.delete(provider: provider)
            } else {
                try await credentialStore.store(trimmed, provider: provider)
            }
            await refresh()
            notice = trimmed.isEmpty ? "Credential removed." : "Credential saved in Keychain."
            return true
        } catch {
            notice = "The credential could not be saved in Keychain."
            return false
        }
    }

    public func testCompatibleProvider() async {
        guard !isCheckingCompatibleProvider else { return }
        isCheckingCompatibleProvider = true
        defer { isCheckingCompatibleProvider = false }
        do {
            let configuration = try compatibleConfiguration()
            try await compatiblePreflight.check(
                baseURL: configuration.url,
                model: configuration.model
            )
            notice = "Connected. `\(configuration.model)` is ready."
        } catch {
            notice = error.localizedDescription
        }
    }

    public func provider() async throws -> any AIProvider {
        switch selectedProvider {
        case .openAICompatible:
            let configuration = try compatibleConfiguration()
            try await compatiblePreflight.check(
                baseURL: configuration.url,
                model: configuration.model
            )
            return OpenAICompatibleProvider(
                baseURL: configuration.url,
                defaultModel: configuration.model,
                ledger: ledger
            )
        case .openAI:
            guard let key = try await credentialStore.key(for: .openAI), !key.isEmpty else {
                throw AIKitError.missingCredential(.openAI)
            }
            return OpenAIProvider(
                apiKey: key, ledger: ledger, defaultModel: effectiveModel(for: .openAI))
        case .anthropic:
            guard let key = try await credentialStore.key(for: .anthropic), !key.isEmpty else {
                throw AIKitError.missingCredential(.anthropic)
            }
            return AnthropicProvider(
                apiKey: key, ledger: ledger,
                defaultModel: effectiveModel(for: .anthropic))
        case .google:
            guard let key = try await credentialStore.key(for: .google), !key.isEmpty else {
                throw AIKitError.missingCredential(.google)
            }
            return GoogleProvider(
                apiKey: key, ledger: ledger,
                defaultModel: effectiveModel(for: .google))
        default:
            throw AIKitError.invalidResponse("Unsupported provider")
        }
    }

    private func compatibleConfiguration() throws -> (url: URL, model: String) {
        let value = compatibleBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty,
            let url = components.url,
            scheme == "http" || scheme == "https"
        else {
            throw AIKitError.invalidResponse("The compatible provider URL is invalid")
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || isLoopback else {
            throw CompatibleProviderSetupError.insecureRemoteURL
        }
        return (url, effectiveModel(for: .openAICompatible))
    }

    private func effectiveModel(for provider: ProviderID) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultModel(for: provider) : trimmed
    }

    private static func restoredModel(for provider: ProviderID, defaults: UserDefaults) -> String {
        if let restored = defaults.string(forKey: modelPreferenceKey(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !restored.isEmpty
        {
            return restored
        }
        return defaultModel(for: provider)
    }

    private static func isSafePersistableBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host?.isEmpty == false
        else { return false }
        return true
    }

    private static func defaultModel(for provider: ProviderID) -> String {
        switch provider {
        case .openAICompatible: "llama3.2"
        case .openAI: "gpt-5.6-sol"
        case .anthropic: "claude-sonnet-4-6"
        case .google: "gemini-2.5-flash"
        default: "local-model"
        }
    }

    private static func modelPreferenceKey(for provider: ProviderID) -> String {
        "clip.ai.model.\(provider.rawValue)"
    }

    private static let supportedProviders: Set<ProviderID> = [
        .openAICompatible, .openAI, .anthropic, .google,
    ]
    private static let providerPreferenceKey = "clip.ai.provider"
    private static let compatibleBaseURLPreferenceKey = "clip.ai.compatibleBaseURL"
    private static let confirmationPreferenceKey = "clip.ai.confirmationPolicy"
    private static let defaultCompatibleBaseURL = "http://localhost:11434/v1"
}
