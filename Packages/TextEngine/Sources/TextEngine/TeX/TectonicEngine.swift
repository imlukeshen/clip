import Darwin
import Foundation

public struct TectonicEngine: TeXEngine {
    public static let version = "0.16.9"

    public let id: EngineID = .tectonic
    public let displayName = "Tectonic"
    public let executableURL: URL
    public let cacheDirectory: URL
    private let networkAccessObserver: @Sendable () async -> Void

    public init(
        executableURL: URL? = nil,
        cacheDirectory: URL? = nil,
        networkAccessObserver: @escaping @Sendable () async -> Void = {}
    ) {
        self.executableURL = executableURL ?? Self.bundledExecutableURL
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
        self.networkAccessObserver = networkAccessObserver
    }

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard isAvailable else {
                    continuation.finish(throwing: TeXEngineError.unavailable)
                    return
                }
                guard job.bibliography != .biber else {
                    continuation.finish(
                        throwing: TeXEngineError.bibliographyToolUnavailable("Biber")
                    )
                    return
                }
                do {
                    let workspace = try TeXWorkspaceSandbox.prepare(job)
                    defer { workspace.remove() }
                    try FileManager.default.createDirectory(
                        at: cacheDirectory,
                        withIntermediateDirectories: true
                    )
                    if job.packageAccess == .allowNetwork {
                        await networkAccessObserver()
                    }
                    continuation.yield(.pass(1, of: 1))
                    let result = try await TeXProcessController().run(
                        executableURL: executableURL,
                        arguments: arguments(for: job, workspace: workspace),
                        currentDirectory: workspace.source,
                        environment: environment(for: job),
                        timeout: job.timeout,
                        logDirectory: workspace.root,
                        logSizeLimit: job.logSizeLimit
                    )
                    for line in result.combinedOutput.components(separatedBy: .newlines)
                    where !line.isEmpty {
                        continuation.yield(.logLine(line))
                    }
                    for diagnostic in TeXLogParser.diagnostics(in: result.combinedOutput) {
                        continuation.yield(.diagnostic(diagnostic))
                    }
                    guard result.status == 0 else {
                        throw TeXEngineError.compilationFailed(
                            status: result.status,
                            message: Self.failureSummary(result.combinedOutput)
                        )
                    }
                    let name = URL(fileURLWithPath: workspace.mainRelativePath)
                        .deletingPathExtension().lastPathComponent
                    let pdf = workspace.output.appendingPathComponent("\(name).pdf")
                    let synctex = workspace.output.appendingPathComponent("\(name).synctex.gz")
                    let resultURLs = try Self.copyValidatedResults(
                        pdf: pdf,
                        synctex: job.synctex ? synctex : nil,
                        sizeLimit: job.outputSizeLimit
                    )
                    try Task.checkCancellation()
                    continuation.yield(
                        .finished(pdf: resultURLs.pdf, synctex: resultURLs.synctex)
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: TeXEngineError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static var bundledExecutableURL: URL {
        Bundle.module.url(
            forResource: "tectonic",
            withExtension: nil,
            subdirectory: "Resources/Tectonic"
        )
            ?? Bundle.module.bundleURL
            .appendingPathComponent("Resources/Tectonic/tectonic", isDirectory: false)
    }

    public static var defaultCacheDirectory: URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Clip/Tectonic", isDirectory: true)
    }

    private func arguments(for job: TeXJob, workspace: TeXWorkspaceSandbox) -> [String] {
        var values = [
            "-X", "compile", "--untrusted", "--keep-logs", "--print",
            "--outdir", workspace.output.path,
        ]
        if job.synctex { values.append("--synctex") }
        if job.packageAccess == .cachedOnly { values.append("--only-cached") }
        if let bundleURL = job.bundleURL {
            values.append(contentsOf: ["--bundle", bundleURL.path])
        }
        values.append(workspace.mainRelativePath)
        return values
    }

    private func environment(for job: TeXJob) -> [String: String] {
        var values = [
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "TECTONIC_UNTRUSTED_MODE": "1",
            "TECTONIC_CACHE_DIR": cacheDirectory.path,
            "openin_any": "p",
            "openout_any": "p",
        ]
        if job.packageAccess == .cachedOnly {
            values["TECTONIC_ONLY_CACHED"] = "1"
        }
        return values
    }

    static func copyValidatedResults(
        pdf: URL,
        synctex: URL?,
        sizeLimit: Int64
    ) throws -> (pdf: URL, synctex: URL?) {
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: pdf.path) else {
            throw TeXEngineError.missingOutput
        }
        let values = try pdf.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TeXEngineError.missingOutput
        }
        guard Int64(values.fileSize ?? 0) <= sizeLimit else {
            throw TeXEngineError.outputTooLarge(limit: sizeLimit)
        }
        let resultRoot = manager.temporaryDirectory.appendingPathComponent(
            "ClipTeXResults/\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: resultRoot, withIntermediateDirectories: true)
        let resultPDF = resultRoot.appendingPathComponent(pdf.lastPathComponent)
        do {
            try manager.copyItem(at: pdf, to: resultPDF)
            var resultSyncTeX: URL?
            if let synctex, manager.isReadableFile(atPath: synctex.path) {
                let destination = resultRoot.appendingPathComponent(synctex.lastPathComponent)
                try manager.copyItem(at: synctex, to: destination)
                resultSyncTeX = destination
            }
            return (resultPDF, resultSyncTeX)
        } catch {
            try? manager.removeItem(at: resultRoot)
            throw error
        }
    }

    static func failureSummary(_ output: String) -> String {
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.suffix(8).joined(separator: "\n")
    }
}

struct TeXProcessResult: Sendable {
    let status: Int32
    let outputText: String
    let errorText: String

    var combinedOutput: String {
        [outputText, errorText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

final class TeXProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String],
        timeout: Duration,
        logDirectory: URL,
        logSizeLimit: Int64
    ) async throws -> TeXProcessResult {
        let outputURL = logDirectory.appendingPathComponent("stdout.log")
        let errorURL = logDirectory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        lock.withLock { self.process = process }
        defer { lock.withLock { self.process = nil } }

        let status = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try await Self.launchAndWait(process)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw TeXEngineError.timedOut
                }
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        try Self.validateLogSize(
                            outputURL: outputURL,
                            errorURL: errorURL,
                            limit: logSizeLimit
                        )
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                do {
                    guard let status = try await group.next() else {
                        throw TeXEngineError.launchFailed("The process ended unexpectedly")
                    }
                    group.cancelAll()
                    return status
                } catch {
                    killProcess()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            killProcess()
        }

        try output.synchronize()
        try error.synchronize()
        try Self.validateLogSize(
            outputURL: outputURL,
            errorURL: errorURL,
            limit: logSizeLimit
        )
        return TeXProcessResult(
            status: status,
            outputText: try Self.readLog(at: outputURL, limit: logSizeLimit),
            errorText: try Self.readLog(at: errorURL, limit: logSizeLimit)
        )
    }

    private static func validateLogSize(
        outputURL: URL,
        errorURL: URL,
        limit: Int64
    ) throws {
        guard limit >= 0 else { throw TeXEngineError.logTooLarge(limit: limit) }
        let outputSize = try logSize(at: outputURL)
        let errorSize = try logSize(at: errorURL)
        guard outputSize <= limit, errorSize <= limit - outputSize else {
            throw TeXEngineError.logTooLarge(limit: limit)
        }
    }

    private static func logSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static func readLog(at url: URL, limit: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let safeLimit = min(limit, Int64(Int.max - 1))
        guard safeLimit >= 0 else { throw TeXEngineError.logTooLarge(limit: limit) }
        let data = try handle.read(upToCount: Int(safeLimit) + 1) ?? Data()
        guard Int64(data.count) <= limit else {
            throw TeXEngineError.logTooLarge(limit: limit)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func launchAndWait(_ process: Process) async throws -> Int32 {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try Task.checkCancellation()
                try process.run()
                if Task.isCancelled, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(
                    throwing: TeXEngineError.launchFailed(error.localizedDescription)
                )
            }
        }
    }

    private func killProcess() {
        lock.withLock {
            guard let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
