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
    /// Whether the assistant may be shown a picture of clipx's own window.
    ///
    /// Off by default. This renders the app's view hierarchy, so it needs no
    /// Screen Recording permission and can never include another app, the
    /// desktop, or anything clipx is not already drawing. It does mean the
    /// window's contents reach whichever provider is configured, which for a
    /// remote one is a real disclosure — hence an explicit switch rather than
    /// something inferred from the model supporting vision.
    public var sharesWindowWithAssistant: Bool {
        didSet { defaults.set(sharesWindowWithAssistant, forKey: Self.windowSharingPreferenceKey) }
    }
    /// The local model used to read the window when the editing model cannot.
    ///
    /// Empty means none. Kept separate from ``model`` because locally the two
    /// roles need two models: the one that emits tool calls generally cannot see,
    /// and the one that sees cannot emit tool calls.
    public var visionModel: String {
        didSet { defaults.set(visionModel, forKey: Self.visionModelPreferenceKey) }
    }
    public private(set) var configuredProviders: [ProviderID] = []
    public private(set) var egressEntries: [EgressEntry] = []
    public private(set) var notice: String?
    public private(set) var isCheckingCompatibleProvider = false
    public private(set) var installedLocalModels: [String] = []
    public private(set) var localModelDownload: LocalModelDownloadState?
    /// What the selected local model reports it can do, for the Settings warning.
    public private(set) var localModelCapabilities: LocalModelCapabilities = .unreported

    public let credentialStore: CredentialStore
    public let ledger: EgressLedger
    private let defaults: UserDefaults
    private let compatiblePreflight: any CompatibleProviderPreflighting
    private let modelInstaller: any LocalModelServing
    private var isRestoringProvider = false
    private var downloadTask: Task<Void, Never>?

    public convenience init(libraryRoot: URL) {
        self.init(
            libraryRoot: libraryRoot,
            defaults: .standard,
            credentialStore: CredentialStore(),
            compatiblePreflight: CompatibleProviderPreflight(),
            modelInstaller: OllamaModelService()
        )
    }

    init(
        libraryRoot: URL,
        defaults: UserDefaults,
        credentialStore: CredentialStore,
        compatiblePreflight: any CompatibleProviderPreflighting,
        modelInstaller: any LocalModelServing = OllamaModelService()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.compatiblePreflight = compatiblePreflight
        self.modelInstaller = modelInstaller
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
        self.sharesWindowWithAssistant = defaults.bool(forKey: Self.windowSharingPreferenceKey)
        self.visionModel = defaults.string(forKey: Self.visionModelPreferenceKey) ?? ""
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
            // Asked fresh rather than cached: the model can be changed from the
            // picker between turns, and sending tool schemas to a model without
            // them is a 400 from Ollama, not a degraded answer.
            let capabilities = await localCapabilities(for: configuration)
            // Both must hold: the person opted in, and the model can read an
            // image. Claiming vision for a model without it means sending a
            // picture that is silently dropped, which reads as the assistant
            // ignoring what is plainly on screen.
            let supportsVision = sharesWindowWithAssistant && capabilities.vision
            // A local Ollama is reached through its native endpoint, the only
            // one that can be told how much context to allocate. Through the
            // compatible one the prompt was cut to fit the server's default
            // before the model read it. Other servers have no such endpoint.
            if OllamaEndpoint.isLocalOllama(configuration.url) {
                return OllamaChatProvider(
                    baseURL: OllamaEndpoint.nativeBaseURL(forCompatible: configuration.url),
                    defaultModel: configuration.model,
                    supportsTools: capabilities.tools,
                    supportsVision: supportsVision,
                    ledger: ledger
                )
            }
            return OpenAICompatibleProvider(
                baseURL: configuration.url,
                defaultModel: configuration.model,
                supportsTools: capabilities.tools,
                supportsVision: supportsVision,
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

    /// Whether the configured compatible server is a local Ollama, which is the
    /// only one clipx can install models into.
    public var canInstallLocalModels: Bool {
        guard selectedProvider == .openAICompatible,
            let configuration = try? compatibleConfiguration()
        else { return false }
        return OllamaEndpoint.isLocalOllama(configuration.url)
    }

    /// Pairings whose models are not both installed yet.
    public var availableLocalModelPairings: [LocalModelPairing] {
        let installed = Set(installedLocalModels.map(Self.withoutLatestTag))
        return LocalModelPairing.catalog.filter { pairing in
            !pairing.models.allSatisfy { installed.contains(Self.withoutLatestTag($0)) }
        }
    }

    /// Suggestions that are not installed yet.
    public var availableLocalModelSuggestions: [LocalModelSuggestion] {
        let installed = Set(installedLocalModels.map(Self.withoutLatestTag))
        return LocalModelSuggestion.catalog.filter {
            !installed.contains(Self.withoutLatestTag($0.name))
        }
    }

    /// Re-reads which models the local server already has, and what the selected
    /// one can do.
    public func refreshInstalledLocalModels() async {
        guard canInstallLocalModels, let native = nativeBaseURL() else {
            installedLocalModels = []
            localModelCapabilities = .unreported
            return
        }
        installedLocalModels =
            (try? await modelInstaller.installedModels(nativeBaseURL: native)) ?? []
        await adoptInstalledModels(nativeBaseURL: native)
        localModelCapabilities = await modelInstaller.capabilities(
            of: model.trimmingCharacters(in: .whitespacesAndNewlines),
            nativeBaseURL: native
        )
    }

    /// Points the two roles at models that are actually present.
    ///
    /// The shipped default is a model name, not a promise that it exists. Left
    /// alone, a fresh install or a removed model leaves the assistant configured
    /// for something the server has never heard of, and every turn fails a
    /// preflight the person cannot act on. Choices already pointing at an
    /// installed model are never overridden.
    private func adoptInstalledModels(nativeBaseURL: URL) async {
        guard !installedLocalModels.isEmpty else { return }
        var roles: [String: LocalModelCapabilities] = [:]
        for name in installedLocalModels {
            roles[name] = await modelInstaller.capabilities(of: name, nativeBaseURL: nativeBaseURL)
        }

        if !installedLocalModels.contains(where: { Self.namesMatch($0, model) }) {
            // Prefer one that can call tools: an editing model that cannot edit
            // is the failure this whole adoption step exists to avoid.
            if let replacement = installedLocalModels.first(where: { roles[$0]?.tools == true })
                ?? installedLocalModels.first
            {
                model = replacement
            }
        }
        if visionModel.isEmpty
            || !installedLocalModels.contains(where: { Self.namesMatch($0, visionModel) })
        {
            visionModel = installedLocalModels.first { roles[$0]?.vision == true } ?? ""
        }
    }

    /// Ollama reports an untagged install as `name:latest`, so the two spellings
    /// have to compare equal.
    private static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        withoutLatestTag(lhs) == withoutLatestTag(rhs.trimmingCharacters(in: .whitespaces))
    }

    /// Installs both halves of a pairing, then points each role at its model.
    public func installPairing(_ pairing: LocalModelPairing) {
        downloadLocalModels(pairing.models) { [weak self] in
            guard let self else { return }
            self.model = pairing.editing
            self.visionModel = pairing.vision
        }
    }

    /// A provider bound to the vision model, when one is configured and the
    /// editing model cannot see for itself.
    ///
    /// Returns nil when the editing model already has vision, since describing
    /// the window in words would then be strictly worse than showing it.
    public func visionProvider() async -> (any AIProvider)? {
        guard sharesWindowWithAssistant, selectedProvider == .openAICompatible,
            let configuration = try? compatibleConfiguration()
        else { return nil }
        let name = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !Self.namesMatch(name, configuration.model) else { return nil }

        let editing = await localCapabilities(for: configuration)
        guard !editing.vision else { return nil }
        let seeing = await localCapabilities(for: (url: configuration.url, model: name))
        guard seeing.vision else { return nil }

        return OpenAICompatibleProvider(
            baseURL: configuration.url,
            defaultModel: name,
            // A vision model that cannot call tools is the normal case, and the
            // describe pass needs none.
            supportsTools: false,
            supportsVision: true,
            ledger: ledger
        )
    }

    /// Why the selected local model will not do what the settings ask of it.
    public var localModelWarning: String? {
        guard canInstallLocalModels, !installedLocalModels.isEmpty else { return nil }
        if !localModelCapabilities.tools {
            return
                "`\(model)` cannot call tools, so it can answer questions but cannot edit "
                + "anything. Choose a model that supports tools."
        }
        if sharesWindowWithAssistant && !localModelCapabilities.vision
            && visionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return
                "`\(model)` cannot read images, and no vision model is chosen, so the window "
                + "will not be seen. Pick one below or install a pair."
        }
        return nil
    }

    private func localCapabilities(
        for configuration: (url: URL, model: String)
    ) async -> LocalModelCapabilities {
        guard OllamaEndpoint.isLocalOllama(configuration.url) else { return .unreported }
        return await modelInstaller.capabilities(
            of: configuration.model,
            nativeBaseURL: OllamaEndpoint.nativeBaseURL(forCompatible: configuration.url)
        )
    }

    /// Installs `name` through the local server, reporting progress as it goes.
    ///
    /// clipx only ever talks to loopback here. Ollama does the downloading, so no
    /// model bytes and no request for them leave through clipx, and nothing is
    /// written to the library.
    public func downloadLocalModel(_ name: String) {
        downloadLocalModels([name]) { [weak self] in self?.model = name }
    }

    /// Installs each model in turn, stopping at the first failure.
    ///
    /// Sequential rather than concurrent: two multi-gigabyte pulls at once are
    /// slower than one after the other on any connection that is the bottleneck,
    /// and one progress bar can only honestly describe one transfer.
    private func downloadLocalModels(
        _ names: [String],
        onCompletion: @escaping @MainActor () -> Void
    ) {
        let requested =
            names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !requested.isEmpty, localModelDownload?.isRunning != true,
            let native = nativeBaseURL()
        else { return }

        notice = nil
        localModelDownload = .running(
            model: requested[0],
            progress: LocalModelDownloadProgress(status: "starting")
        )
        downloadTask = Task { [modelInstaller] in
            for name in requested {
                localModelDownload = .running(
                    model: name,
                    progress: LocalModelDownloadProgress(status: "starting")
                )
                do {
                    guard try await pull(name, from: native, using: modelInstaller) else { return }
                } catch is CancellationError {
                    localModelDownload = nil
                    return
                } catch {
                    localModelDownload = .failed(
                        model: name,
                        message: "Ollama is not reachable. Start it and try again."
                    )
                    return
                }
            }
            localModelDownload = nil
            onCompletion()
            await refreshInstalledLocalModels()
            notice =
                requested.count == 1
                ? "Installed `\(requested[0])`."
                : "Installed \(requested.map { "`\($0)`" }.joined(separator: " and "))."
        }
    }

    /// Runs one pull to completion. Returns false once a failure has been shown.
    private func pull(
        _ name: String,
        from native: URL,
        using installer: any LocalModelServing
    ) async throws -> Bool {
        for try await event in installer.pull(name, nativeBaseURL: native) {
            switch event {
            case .progress(let progress):
                localModelDownload = .running(model: name, progress: progress)
            case .finished:
                return true
            case .failed(let message):
                localModelDownload = .failed(model: name, message: message)
                return false
            }
        }
        // The stream ended without a success line, which happens when the server
        // closes mid-transfer. Treating that as done would select a model that
        // is not actually installed.
        localModelDownload = .failed(
            model: name,
            message: "The download ended before it finished."
        )
        return false
    }

    /// Drops both role models from the local server's memory.
    ///
    /// Called when clipx quits. Ollama holds a model for five minutes after the
    /// last request, so without this a server the person thinks they are done
    /// with keeps several gigabytes resident well after the app is gone.
    /// Awaited rather than fired and forgotten, because the process is about to
    /// end and an unawaited task would simply die first.
    public func releaseLocalModels() async {
        guard let native = nativeBaseURL() else { return }
        for name in Set([model, visionModel]) where !name.isEmpty {
            await modelInstaller.unload(name, nativeBaseURL: native)
        }
    }

    public func cancelLocalModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        localModelDownload = nil
    }

    public func dismissLocalModelDownloadFailure() {
        guard localModelDownload?.isRunning == false else { return }
        localModelDownload = nil
    }

    private func nativeBaseURL() -> URL? {
        guard let configuration = try? compatibleConfiguration(),
            OllamaEndpoint.isLocalOllama(configuration.url)
        else { return nil }
        return OllamaEndpoint.nativeBaseURL(forCompatible: configuration.url)
    }

    /// Ollama reports an untagged install as `name:latest`, so the two spellings
    /// have to compare equal or every suggestion looks uninstalled.
    private static func withoutLatestTag(_ name: String) -> String {
        name.hasSuffix(":latest") ? String(name.dropLast(":latest".count)) : name
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
    private static let windowSharingPreferenceKey = "clip.ai.sharesWindow"
    private static let visionModelPreferenceKey = "clip.ai.visionModel"
    private static let confirmationPreferenceKey = "clip.ai.confirmationPolicy"
    private static let defaultCompatibleBaseURL = "http://localhost:11434/v1"
}
