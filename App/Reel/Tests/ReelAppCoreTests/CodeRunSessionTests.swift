import CoreModel
import Foundation
import Testing
import TextEngine

@testable import ReelAppCore

@MainActor
@Suite("Code run session")
struct CodeRunSessionTests {
    @Test("Output becomes terminal lines, and a failure points at its line")
    func transcriptAndErrorLine() async {
        let session = CodeRunSession(
            runner: StubRunner(events: [
                .started(commandLine: "python3 -u -B solver.py"),
                .output("sta", .standardOutput),
                .output("rt\nnext\n", .standardOutput),
                .output(
                    "  File \"solver.py\", line 3, in <module>\nValueError: bad\n", .standardError),
                .finished(exitStatus: 1, duration: .milliseconds(20)),
            ])
        )
        session.run(
            source: "", language: .python, fileName: "/tmp/solver.py", workingDirectory: nil)
        #expect(session.isRunning)
        await waitUntilSettled(session)
        #expect(session.state == .finished(exitStatus: 1, duration: .milliseconds(20)))
        #expect(
            session.transcript.lines.map(\.text) == [
                "python3 -u -B solver.py", "start", "next",
                "  File \"solver.py\", line 3, in <module>", "ValueError: bad",
            ])
        #expect(session.transcript.lines.first?.kind == .command)
        #expect(session.transcript.lines.last?.kind == .error)
        #expect(session.errorLine == 3)
    }

    @Test("A missing toolchain says what to install")
    func missingToolchain() async {
        let session = CodeRunSession(runner: StubRunner(failure: .runToolchainUnavailable(.rust)))
        session.run(source: "", language: .rust, fileName: "main.rs", workingDirectory: nil)
        await waitUntilSettled(session)
        guard case .failed(let message) = session.state else {
            Issue.record("Expected a failure")
            return
        }
        #expect(message.contains("Rust isn't installed"))
    }

    @Test("Markup is never offered a Run button")
    func markupIsNotRunnable() {
        let session = CodeRunSession(runner: StubRunner(events: []))
        #expect(session.isRunnable(.python))
        #expect(session.isRunnable(.go))
        #expect(!session.isRunnable(.json))
        #expect(!session.isRunnable(.markdown))
    }

    @Test("A build without a runner offers nothing")
    func unsupportedBuild() {
        let session = CodeRunSession(runner: nil)
        #expect(!session.isRunnable(.python))
        session.run(source: "print(1)", language: .python, fileName: "a.py", workingDirectory: nil)
        #expect(session.state == .idle)
    }

    @Test("An unfinished line still shows, then joins the transcript at exit")
    func partialLinesShow() {
        var transcript = CodeTranscript()
        transcript.append("progress", from: .standardOutput)
        #expect(transcript.lines.isEmpty)
        #expect(transcript.displayLines.map(\.text) == ["progress"])
        transcript.flush()
        #expect(transcript.lines.map(\.text) == ["progress"])
        #expect(transcript.plainText == "progress")
    }

    private func waitUntilSettled(_ session: CodeRunSession) async {
        for _ in 0..<200 where session.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct StubRunner: CodeRunning {
    var events: [CodeRunEvent] = []
    var failure: TextEngineError?

    func canRun(_ language: LanguageID) -> Bool { true }

    func run(_ request: CodeRunRequest) -> AsyncThrowingStream<CodeRunEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: failure)
        }
    }
}
