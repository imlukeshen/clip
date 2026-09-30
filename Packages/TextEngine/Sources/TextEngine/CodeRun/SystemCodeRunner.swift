import CoreModel
import Foundation
import os

/// Runs programs with toolchains already installed on the Mac.
///
/// Used only by the unsandboxed direct-download build. A program runs as the
/// user with the user's own permissions, like running it from Terminal, but
/// with no standard input, a hard timeout, and a cap on how much it may print.
public struct SystemCodeRunner: CodeRunning {
    /// The most output a run may produce before it is stopped.
    public static let outputLimit: Int64 = 5 * 1_024 * 1_024

    /// Creates a runner.
    public init() {}

    public func canRun(_ language: LanguageID) -> Bool {
        CodeToolchain.toolchain(for: language)?.locate() != nil
    }

    public func run(_ request: CodeRunRequest) -> AsyncThrowingStream<CodeRunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clipx-run", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    let status = try await Self.execute(request, in: root, continuation)
                    continuation.yield(
                        .finished(exitStatus: status.exit, duration: status.duration))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // Best effort: the staging folder is in the temporary directory,
                // which macOS clears on its own if this removal fails.
                try? FileManager.default.removeItem(at: root)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func execute(
        _ request: CodeRunRequest,
        in root: URL,
        _ continuation: AsyncThrowingStream<CodeRunEvent, any Error>.Continuation
    ) async throws -> (exit: Int32, duration: Duration) {
        guard let toolchain = CodeToolchain.toolchain(for: request.language),
            let tool = toolchain.locate()
        else { throw TextEngineError.runToolchainUnavailable(request.language) }
        let sourceURL = root.appendingPathComponent(request.fileName)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(request.source.utf8).write(to: sourceURL)
        } catch {
            throw TextEngineError.runLaunchFailed("The program could not be staged to run.")
        }
        let steps = toolchain.plan(tool, sourceURL, root)
        let workingDirectory = request.workingDirectory ?? root
        let environment = environment(workingDirectory: workingDirectory)
        let budget = OSAllocatedUnfairLock(initialState: outputLimit)
        let stagedPrefix = root.path + "/"
        let onOutput: @Sendable (String, CodeOutputStream) -> Void = { text, stream in
            // Errors name the staged copy; show the user's own file name instead.
            continuation.yield(
                .output(text.replacingOccurrences(of: stagedPrefix, with: ""), stream))
        }
        let start = ContinuousClock.now
        let timeout = request.timeout
        let exit = try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                var status: Int32 = 0
                for step in steps {
                    continuation.yield(.started(commandLine: step.commandLine(replacing: root)))
                    status = try await CodeProcessStep(
                        step: step,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        budget: budget,
                        onOutput: onOutput
                    ).run()
                    // A failed build leaves nothing to run.
                    if status != 0 { break }
                }
                return status
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TextEngineError.runTimedOut(timeout)
            }
            defer { group.cancelAll() }
            guard let status = try await group.next() else {
                throw TextEngineError.runLaunchFailed("The program ended unexpectedly.")
            }
            return status
        }
        return (exit, ContinuousClock.now - start)
    }

    private static func environment(workingDirectory: URL) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = [
            "PATH": [
                "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin", "/usr/bin", "/bin",
            ].joined(separator: ":"),
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "PYTHONIOENCODING": "utf-8",
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            // The source is staged elsewhere, so put its real folder on the
            // import path for sibling modules.
            "PYTHONPATH": workingDirectory.path,
            "NODE_PATH": workingDirectory.appendingPathComponent("node_modules").path,
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] {
            environment["USER"] = user
        }
        return environment
    }
}
