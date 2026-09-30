import Foundation
import os

/// One launched command, forwarding its pipes as they fill.
///
/// Output from both pipes, the exit, and cancellation arrive on different
/// threads in any order. They meet in one lock-protected state, and ``run()``
/// returns once the process has exited and both pipes have drained.
final class CodeProcessStep: Sendable {
    private struct State {
        var decoders: [CodeOutputStream: UTF8ChunkDecoder] = [
            .standardOutput: UTF8ChunkDecoder(), .standardError: UTF8ChunkDecoder(),
        ]
        var openPipes = 2
        var exitStatus: Int32?
        var floodLimit: Int64?
        var completion: CheckedContinuation<Int32, any Error>?
    }

    private let process: OSAllocatedUnfairLock<Process>
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let budget: OSAllocatedUnfairLock<Int64>
    private let onOutput: @Sendable (String, CodeOutputStream) -> Void

    init(
        step: CodeRunStep,
        workingDirectory: URL,
        environment: [String: String],
        budget: OSAllocatedUnfairLock<Int64>,
        onOutput: @escaping @Sendable (String, CodeOutputStream) -> Void
    ) {
        let process = Process()
        process.executableURL = step.executableURL
        process.arguments = step.arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        self.process = OSAllocatedUnfairLock(uncheckedState: process)
        self.budget = budget
        self.onOutput = onOutput
    }

    /// Runs the command to completion and returns its exit status.
    func run() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                state.withLock { $0.completion = completion }
                launch()
            }
        } onCancel: {
            stop()
        }
    }

    private func launch() {
        let output = Pipe()
        let error = Pipe()
        forward(output, as: .standardOutput)
        forward(error, as: .standardError)
        let launched: Result<Void, any Error> = process.withLockUnchecked { process in
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { [weak self] finished in
                let status = finished.terminationStatus
                self?.state.withLock { $0.exitStatus = status }
                self?.resumeIfDone()
            }
            return Result { try process.run() }
        }
        if case .failure(let failure) = launched {
            let completion = state.withLock { state in
                defer { state.completion = nil }
                return state.completion
            }
            completion?.resume(
                throwing: TextEngineError.runLaunchFailed(failure.localizedDescription))
            return
        }
        if Task.isCancelled { stop() }
    }

    /// Kills the command. Safe to call at any time, including twice.
    func stop() {
        process.withLockUnchecked { process in
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func forward(_ pipe: Pipe, as stream: CodeOutputStream) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                let tail = self.state.withLock { state -> String in
                    state.openPipes -= 1
                    return state.decoders[stream]?.flush() ?? ""
                }
                if !tail.isEmpty { self.onOutput(tail, stream) }
                self.resumeIfDone()
                return
            }
            let remaining = self.budget.withLock { remaining in
                remaining -= Int64(data.count)
                return remaining
            }
            guard remaining >= 0 else {
                self.state.withLock { $0.floodLimit = SystemCodeRunner.outputLimit }
                self.stop()
                return
            }
            let text = self.state.withLock { $0.decoders[stream]?.decode(data) ?? "" }
            if !text.isEmpty { self.onOutput(text, stream) }
        }
    }

    private func resumeIfDone() {
        let outcome: (CheckedContinuation<Int32, any Error>, Result<Int32, any Error>)? =
            state.withLock { state in
                guard state.openPipes == 0, let status = state.exitStatus,
                    let completion = state.completion
                else { return nil }
                state.completion = nil
                if let limit = state.floodLimit {
                    return (completion, .failure(TextEngineError.runOutputTooLarge(limit: limit)))
                }
                return (completion, .success(status))
            }
        guard let (completion, result) = outcome else { return }
        completion.resume(with: result)
    }
}
