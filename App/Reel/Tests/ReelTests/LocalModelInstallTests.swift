import Foundation
import Testing

@testable import ReelAppCore

@Suite("Local model install")
struct LocalModelInstallTests {
    @Test("A transfer line becomes progress")
    func progressLine() throws {
        let event = LocalModelPullEvent(
            line: #"{"status":"pulling 8eeb52dfb3bb","total":4920000000,"completed":1230000000}"#
        )
        guard case .progress(let progress) = try #require(event) else {
            Issue.record("expected progress")
            return
        }
        #expect(progress.status == "pulling 8eeb52dfb3bb")
        #expect(progress.totalBytes == 4_920_000_000)
        #expect(progress.fraction == 0.25)
        #expect(progress.byteSummary != nil)
    }

    @Test("Steps that move no bytes report no fraction")
    func indeterminateSteps() throws {
        let event = try #require(LocalModelPullEvent(line: #"{"status":"pulling manifest"}"#))
        guard case .progress(let progress) = event else {
            Issue.record("expected progress")
            return
        }
        // A determinate bar pinned at zero through the manifest and verification
        // steps reads as a stall, so these have to be distinguishable.
        #expect(progress.fraction == nil)
        #expect(progress.byteSummary == nil)
    }

    @Test("Success and refusal are told apart")
    func terminalLines() {
        #expect(LocalModelPullEvent(line: #"{"status":"success"}"#) == .finished)
        // A refusal arrives as a 200 with an error field, so it cannot be
        // detected from the HTTP status alone.
        #expect(
            LocalModelPullEvent(line: #"{"error":"model 'nope' not found"}"#)
                == .failed("model 'nope' not found")
        )
    }

    @Test("Noise between objects is skipped rather than ending the stream")
    func unreadableLines() {
        #expect(LocalModelPullEvent(line: "") == nil)
        #expect(LocalModelPullEvent(line: "   ") == nil)
        #expect(LocalModelPullEvent(line: "not json") == nil)
        #expect(LocalModelPullEvent(line: "{}") == nil)
    }

    @Test("The native API root is the compatible URL without its v1 suffix")
    func nativeBaseURL() throws {
        let compatible = try #require(URL(string: "http://localhost:11434/v1"))
        #expect(
            OllamaEndpoint.nativeBaseURL(forCompatible: compatible).absoluteString
                == "http://localhost:11434"
        )
        let bare = try #require(URL(string: "http://127.0.0.1:11434"))
        #expect(
            OllamaEndpoint.nativeBaseURL(forCompatible: bare).absoluteString
                == "http://127.0.0.1:11434"
        )
    }

    @Test("Installing is offered only for a loopback server on Ollama's port")
    func onlyLocalOllamaInstalls() throws {
        #expect(
            OllamaEndpoint.isLocalOllama(try #require(URL(string: "http://localhost:11434/v1"))))
        #expect(
            OllamaEndpoint.isLocalOllama(try #require(URL(string: "http://127.0.0.1:11434/v1"))))
        // LM Studio's default port, and a remote host: neither takes /api/pull,
        // and a remote one would be someone else's disk.
        #expect(
            !OllamaEndpoint.isLocalOllama(try #require(URL(string: "http://localhost:1234/v1"))))
        #expect(
            !OllamaEndpoint.isLocalOllama(try #require(URL(string: "https://example.com:11434/v1")))
        )
    }

    @Test("Every suggested model is offered by name and size")
    func catalogIsUsable() {
        #expect(!LocalModelSuggestion.catalog.isEmpty)
        for suggestion in LocalModelSuggestion.catalog {
            #expect(!suggestion.name.isEmpty)
            #expect(!suggestion.summary.isEmpty)
            #expect(suggestion.approximateGigabytes > 0)
        }
        let names = LocalModelSuggestion.catalog.map(\.name)
        #expect(Set(names).count == names.count)
    }
}
