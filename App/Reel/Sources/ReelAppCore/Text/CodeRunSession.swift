import CoreModel
import Foundation
import Observation
import TextEngine

/// Runs the editor's buffer on request and keeps its terminal transcript.
///
/// One session per open editor. A new run replaces the previous transcript, so
/// the output always describes the source the user last asked to run.
@MainActor
@Observable
public final class CodeRunSession {
    /// Whether this build can run code at all. The App Store build cannot,
    /// and hides the Run button rather than offering one that always fails.
    public var isSupported: Bool { runner != nil }
    public private(set) var state: CodeRunState = .idle
    public private(set) var transcript = CodeTranscript()
    /// The file name and language of the last run, for locating errors.
    public private(set) var fileName = ""
    public private(set) var language: LanguageID = .plainText

    @ObservationIgnored private let runner: (any CodeRunning)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Creates a session; pass `nil` in builds that cannot run code.
    public init(runner: (any CodeRunning)?) {
        self.runner = runner
    }

    public var isRunning: Bool { state == .running }

    /// Whether `language` is a programming language clipx knows how to run.
    /// Its toolchain may still be missing; running then explains how to get it.
    public func isRunnable(_ language: LanguageID) -> Bool {
        isSupported && CodeToolchain.toolchain(for: language) != nil
    }

    /// The line in the user's file that the last failure blames.
    public var errorLine: Int? {
        guard case .finished(let status, _) = state, status != 0 else { return nil }
        return RunErrorLocator.errorLine(
            in: transcript.errorText,
            fileName: fileName,
            language: language
        )
    }

    /// Runs `source`, stopping any run already in progress.
    public func run(
        source: String,
        language: LanguageID,
        fileName: String,
        workingDirectory: URL?
    ) {
        guard let runner, isRunnable(language) else { return }
        task?.cancel()
        generation += 1
        let generation = generation
        let request = CodeRunRequest(
            language: language,
            source: source,
            fileName: fileName,
            workingDirectory: workingDirectory
        )
        self.fileName = request.fileName
        self.language = language
        transcript = CodeTranscript()
        state = .running
        task = Task { [weak self] in
            do {
                for try await event in runner.run(request) {
                    guard let self, self.generation == generation else { return }
                    self.apply(event)
                }
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.transcript.flush()
                self.state = .failed(Self.message(for: error, language: language))
            }
        }
    }

    /// Stops the running program and says so in the transcript.
    public func stop() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        generation += 1
        transcript.flush()
        state = .failed("Stopped.")
    }

    /// Empties the terminal.
    public func clear() {
        guard !isRunning else { return }
        transcript = CodeTranscript()
        state = .idle
    }

    private func apply(_ event: CodeRunEvent) {
        switch event {
        case .started(let commandLine):
            transcript.appendCommand(commandLine)
        case .output(let text, let stream):
            transcript.append(text, from: stream)
        case .finished(let exitStatus, let duration):
            transcript.flush()
            state = .finished(exitStatus: exitStatus, duration: duration)
        }
    }

    static func message(for error: any Error, language: LanguageID) -> String {
        guard let error = error as? TextEngineError else { return "The program could not run." }
        switch error {
        case .runToolchainUnavailable:
            let toolchain = CodeToolchain.toolchain(for: language)
            return "\(toolchain?.displayName ?? "The toolchain") isn't installed. "
                + (toolchain?.installHint ?? "")
        case .runTimedOut(let limit):
            return
                "Stopped after \(limit.components.seconds) seconds. clipx runs short programs; use Terminal for long ones."
        case .runOutputTooLarge:
            return "Stopped because the program printed more output than clipx can show."
        case .runLaunchFailed(let reason):
            return "The program could not start: \(reason)"
        default:
            return "The program could not run."
        }
    }
}
