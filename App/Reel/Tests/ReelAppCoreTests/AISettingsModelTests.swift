import AIKit
import Foundation
import Testing

@testable import ReelAppCore

private actor StubCompatiblePreflight: CompatibleProviderPreflighting {
    enum Outcome: Sendable, Equatable { case success, unavailable }

    let outcome: Outcome
    private(set) var calls: [(URL, String)] = []

    init(outcome: Outcome = .success) { self.outcome = outcome }

    func check(baseURL: URL, model: String) async throws {
        calls.append((baseURL, model))
        if outcome == .unavailable {
            throw CompatibleProviderSetupError.unavailable(
                isOllama: true,
                model: model
            )
        }
    }
}

private actor FixtureLocalModelTransport: LocalModelHTTPTransport {
    enum Outcome: Sendable {
        case response(Data, Int)
        case unavailable
    }

    let outcome: Outcome
    private(set) var request: URLRequest?

    init(_ outcome: Outcome) { self.outcome = outcome }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        switch outcome {
        case .unavailable:
            throw URLError(.cannotConnectToHost)
        case .response(let data, let status):
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(fileURLWithPath: "/"),
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (data, response)
        }
    }
}

@Suite("AI provider settings", .serialized)
struct AISettingsModelTests {
    @Test("Provider models are scoped, defaulted, and restored independently")
    @MainActor
    func providerModelsPersistIndependently() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()

        #expect(settings.selectedProvider == .openAICompatible)
        #expect(settings.model == "llama3.2")
        settings.model = "qwen3:8b"

        settings.selectProvider(.openAI)
        #expect(settings.model == "gpt-5.6-sol")
        settings.model = "gpt-custom"
        settings.selectProvider(.anthropic)
        #expect(settings.model == "claude-sonnet-4-6")
        settings.selectProvider(.openAICompatible)
        #expect(settings.model == "qwen3:8b")

        let reopened = fixture.settings()
        #expect(reopened.selectedProvider == .openAICompatible)
        #expect(reopened.model == "qwen3:8b")
        reopened.selectProvider(.openAI)
        #expect(reopened.model == "gpt-custom")
    }

    @Test("Compatible URL and confirmation policy persist without URL credentials")
    @MainActor
    func safePreferencesPersist() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        settings.compatibleBaseURL = "http://127.0.0.1:1234/v1"
        settings.confirmationPolicy = .confirmAll

        var reopened = fixture.settings()
        #expect(reopened.compatibleBaseURL == "http://127.0.0.1:1234/v1")
        #expect(reopened.confirmationPolicy == .confirmAll)

        reopened.compatibleBaseURL = "https://secret@example.test/v1?key=do-not-store"
        reopened = fixture.settings()
        #expect(reopened.compatibleBaseURL == "http://127.0.0.1:1234/v1")
        let domain = fixture.defaults.persistentDomain(forName: fixture.suiteName) ?? [:]
        #expect(!String(describing: domain).contains("do-not-store"))
    }

    @Test("Residency disclosure follows the configured provider endpoint")
    @MainActor
    func residencyDisclosure() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()

        #expect(settings.usesLoopbackAssistantEndpoint)
        settings.compatibleBaseURL = "https://models.example.test/v1"
        #expect(!settings.usesLoopbackAssistantEndpoint)
        settings.selectProvider(.openAI)
        #expect(!settings.usesLoopbackAssistantEndpoint)
    }

    @Test("Local provider construction performs readiness preflight")
    @MainActor
    func providerRunsPreflight() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let preflight = StubCompatiblePreflight()
        let settings = fixture.settings(preflight: preflight)

        let provider = try await settings.provider()
        #expect(provider.defaultModel == "llama3.2")
        let calls = await preflight.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0.absoluteString == "http://localhost:11434/v1")
        #expect(calls.first?.1 == "llama3.2")
    }

    @Test("Ollama connection failures produce actionable guidance")
    @MainActor
    func ollamaFailureIsActionable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings(
            preflight: StubCompatiblePreflight(outcome: .unavailable)
        )

        await settings.testCompatibleProvider()
        #expect(settings.notice?.contains("Start Ollama") == true)
        #expect(settings.notice?.contains("ollama pull llama3.2") == true)
    }

    @Test("Ollama preflight checks the model list without credentials")
    func ollamaModelListRequestIsPrivate() async throws {
        let transport = FixtureLocalModelTransport(
            .response(Data(#"{"data":[{"id":"llama3.2:latest"}]}"#.utf8), 200)
        )
        let preflight = CompatibleProviderPreflight(transport: transport)
        try await preflight.check(
            baseURL: try #require(URL(string: "http://localhost:11434/v1")),
            model: "llama3.2"
        )

        let request = try #require(await transport.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
    }

    @Test("Ollama reports an installed-server missing-model failure")
    func ollamaMissingModelIsActionable() async throws {
        let transport = FixtureLocalModelTransport(
            .response(Data(#"{"data":[{"id":"qwen3:8b"}]}"#.utf8), 200)
        )
        let preflight = CompatibleProviderPreflight(transport: transport)
        await #expect(
            throws: CompatibleProviderSetupError.modelMissing(
                "llama3.2",
                isOllama: true
            )
        ) {
            try await preflight.check(
                baseURL: try #require(URL(string: "http://localhost:11434/v1")),
                model: "llama3.2"
            )
        }
    }

    private func makeFixture() throws -> SettingsFixture {
        try SettingsFixture()
    }
}

private struct SettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let root: URL
    let credentialStore: CredentialStore

    init() throws {
        suiteName = "clip.ai-settings-tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-ai-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        credentialStore = CredentialStore(service: "clip.ai-settings-tests.\(UUID().uuidString)")
    }

    @MainActor
    func settings(
        preflight: any CompatibleProviderPreflighting = StubCompatiblePreflight()
    ) -> AISettingsModel {
        AISettingsModel(
            libraryRoot: root,
            defaults: defaults,
            credentialStore: credentialStore,
            compatiblePreflight: preflight
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
