import AIKit
import Foundation
import Testing

@testable import ReelAppCore

@MainActor
@Suite("Local model capabilities")
struct LocalModelCapabilitiesTests {
    @Test("Ollama's reported capabilities are read verbatim")
    func readsReportedCapabilities() {
        // The exact array a local Ollama 0.35 returns from /api/show for
        // llava:7b. Sending tool schemas to this model is answered with
        // "does not support tools" and HTTP 400, which failed every assistant
        // turn rather than only the ones carrying an image.
        let vision = LocalModelCapabilities(reported: ["completion", "vision"])
        #expect(!vision.tools)
        #expect(vision.vision)

        let tooling = LocalModelCapabilities(reported: ["completion", "tools"])
        #expect(tooling.tools)
        #expect(!tooling.vision)

        let both = LocalModelCapabilities(reported: ["completion", "tools", "vision"])
        #expect(both.tools)
        #expect(both.vision)
    }

    @Test("A server that reports nothing keeps the behaviour clipx had before")
    func unreportedKeepsToolCalling() {
        // LM Studio and llama.cpp have no /api/show. Treating silence as "no
        // tools" would take tool calling away from every non-Ollama server.
        #expect(LocalModelCapabilities.unreported.tools)
        #expect(!LocalModelCapabilities.unreported.vision)
        #expect(
            LocalModelCapabilities(reported: [])
                == LocalModelCapabilities(
                    tools: false, vision: false))
    }

    @Test("A model that cannot call tools is reported as unable to edit")
    func warnsWhenToolsMissing() async {
        let settings = makeSettings(capabilities: .init(tools: false, vision: true))
        await settings.refreshInstalledLocalModels()
        let warning = try? #require(settings.localModelWarning)
        #expect(warning?.contains("cannot call tools") == true)
    }

    @Test("Window sharing with a blind model is reported rather than silently ignored")
    func warnsWhenVisionMissing() async {
        let settings = makeSettings(capabilities: .init(tools: true, vision: false))
        settings.sharesWindowWithAssistant = true
        await settings.refreshInstalledLocalModels()
        let warning = try? #require(settings.localModelWarning)
        #expect(warning?.contains("cannot read images") == true)
    }

    @Test("A capable model produces no warning")
    func capableModelIsQuiet() async {
        let settings = makeSettings(capabilities: .init(tools: true, vision: true))
        settings.sharesWindowWithAssistant = true
        await settings.refreshInstalledLocalModels()
        #expect(settings.localModelWarning == nil)
    }

    @Test("An uninstalled saved model is replaced by one that is present")
    func adoptsInstalledModel() async {
        let settings = makeSettings(
            capabilities: .init(tools: true, vision: false),
            installed: ["qwen3:4b", "llava:7b"],
            byName: [
                "qwen3:4b": .init(tools: true, vision: false),
                "llava:7b": .init(tools: false, vision: true),
            ]
        )
        // The shipped default names a model, it does not promise one exists.
        #expect(settings.model == "fixture-model")
        await settings.refreshInstalledLocalModels()
        // Prefers the one that can call tools: an editing model that cannot edit
        // is the failure adoption exists to avoid.
        #expect(settings.model == "qwen3:4b")
        #expect(settings.visionModel == "llava:7b")
    }

    @Test("A model that is already installed is left alone")
    func keepsValidChoice() async {
        let settings = makeSettings(
            capabilities: .init(tools: true, vision: false),
            installed: ["fixture-model", "other:8b"],
            byName: [
                "fixture-model": .init(tools: true, vision: false),
                "other:8b": .init(tools: true, vision: false),
            ]
        )
        await settings.refreshInstalledLocalModels()
        #expect(settings.model == "fixture-model")
        // No vision model installed, so the role stays empty rather than being
        // filled with something that cannot see.
        #expect(settings.visionModel.isEmpty)
    }

    @Test("A pairing is offered only until both of its models are installed")
    func pairingsHideOnceInstalled() async {
        let pairing = LocalModelPairing.catalog[0]
        let settings = makeSettings(
            capabilities: .init(tools: true, vision: false),
            installed: pairing.models,
            byName: [:]
        )
        await settings.refreshInstalledLocalModels()
        #expect(!settings.availableLocalModelPairings.contains(pairing))
    }

    private func makeSettings(
        capabilities: LocalModelCapabilities,
        installed: [String] = ["fixture-model"],
        byName: [String: LocalModelCapabilities] = [:]
    ) -> AISettingsModel {
        let defaults = UserDefaults(suiteName: "clip.tests.\(UUID().uuidString)") ?? .standard
        defaults.set("openai-compatible", forKey: "clip.ai.provider")
        defaults.set("http://localhost:11434/v1", forKey: "clip.ai.compatibleBaseURL")
        defaults.set("fixture-model", forKey: "clip.ai.model.openai-compatible")
        return AISettingsModel(
            libraryRoot: FileManager.default.temporaryDirectory,
            defaults: defaults,
            credentialStore: CredentialStore(),
            compatiblePreflight: NeverPreflight(),
            modelInstaller: StubService(
                capabilities: capabilities, installed: installed, byName: byName)
        )
    }
}

private struct NeverPreflight: CompatibleProviderPreflighting {
    func check(baseURL: URL, model: String) async throws {}
}

private struct StubService: LocalModelServing {
    let capabilities: LocalModelCapabilities
    let installed: [String]
    let byName: [String: LocalModelCapabilities]

    func installedModels(nativeBaseURL: URL) async throws -> [String] { installed }

    func capabilities(of model: String, nativeBaseURL: URL) async -> LocalModelCapabilities {
        byName[model] ?? capabilities
    }

    func unload(_ model: String, nativeBaseURL: URL) async {}

    func pull(
        _ model: String,
        nativeBaseURL: URL
    ) -> AsyncThrowingStream<LocalModelPullEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
