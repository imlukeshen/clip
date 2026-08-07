import Darwin
import Foundation

public struct TectonicEngine: TeXEngine, TeXEngineActivityAwaiting {
    public static let version = "0.16.9"

    public let id: EngineID = .tectonic
    public let displayName = "Tectonic"
    public let executableURL: URL
    public let cacheDirectory: URL
    private let networkAccessObserver: @Sendable () async -> Void
    private let activity = TeXEngineActivity()

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

    public func waitUntilIdle() async {
        await activity.waitUntilIdle()
    }

    public func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        AsyncThrowingStream { continuation in
            activity.begin()
            let task = Task {
                defer { activity.end() }
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
                    var workspace = try TeXWorkspaceSandbox.prepare(job)
                    defer { workspace.remove() }
                    try FileManager.default.createDirectory(
                        at: cacheDirectory,
                        withIntermediateDirectories: true
                    )
                    continuation.yield(.pass(1, of: 1))
                    let controller = TeXProcessController()
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: job.timeout)
                    func remainingTimeout() throws -> Duration {
                        let remaining = clock.now.duration(to: deadline)
                        guard remaining > .zero else { throw TeXEngineError.timedOut }
                        return remaining
                    }
                    let result: TeXProcessResult
                    if job.packageAccess == .allowNetwork, isCacheReady(for: job) {
                        // Most builds need no network once their packages are cached. Trying
                        // the confined cache first avoids a remote bundle check on every click.
                        // A genuine cache miss retries once with the user's existing consent.
                        var cachedJob = job
                        cachedJob.packageAccess = .cachedOnly
                        let cachedResult = try await controller.run(
                            executableURL: executableURL,
                            arguments: arguments(for: cachedJob, workspace: workspace),
                            currentDirectory: workspace.source,
                            environment: environment(for: cachedJob),
                            timeout: try remainingTimeout(),
                            logDirectory: workspace.root.appendingPathComponent(
                                "cached-attempt", isDirectory: true
                            ),
                            logSizeLimit: job.logSizeLimit
                        )
                        if cachedResult.status == 0
                            || Self.cachedResourceMiss(in: cachedResult.combinedOutput) == nil
                        {
                            result = cachedResult
                        } else {
                            // A compiler may leave auxiliary or generated files beside the
                            // source. Restage the immutable job rather than letting those
                            // side effects leak into the network-enabled attempt.
                            workspace.remove()
                            workspace = try TeXWorkspaceSandbox.prepare(job)
                            await networkAccessObserver()
                            result = try await controller.run(
                                executableURL: executableURL,
                                arguments: arguments(for: job, workspace: workspace),
                                currentDirectory: workspace.source,
                                environment: environment(for: job),
                                timeout: try remainingTimeout(),
                                logDirectory: workspace.root,
                                logSizeLimit: job.logSizeLimit
                            )
                        }
                    } else {
                        if job.packageAccess == .allowNetwork {
                            // A new library has no bundle digest or format files to probe.
                            // Its first approved build must populate the cache directly.
                            await networkAccessObserver()
                        }
                        result = try await controller.run(
                            executableURL: executableURL,
                            arguments: arguments(for: job, workspace: workspace),
                            currentDirectory: workspace.source,
                            environment: environment(for: job),
                            timeout: try remainingTimeout(),
                            logDirectory: workspace.root,
                            logSizeLimit: job.logSizeLimit
                        )
                    }
                    if !result.combinedOutput.isEmpty {
                        // Publish one bounded log chunk. Thousands of individual observable
                        // string appends made a completed compile look stuck in the UI.
                        continuation.yield(.logLine(result.combinedOutput))
                    }
                    for diagnostic in TeXLogParser.diagnostics(in: result.combinedOutput) {
                        continuation.yield(.diagnostic(diagnostic))
                    }
                    try Task.checkCancellation()
                    if result.status != 0, job.packageAccess == .cachedOnly,
                        let resource = Self.cachedResourceMiss(in: result.combinedOutput)
                    {
                        throw TeXEngineError.packageUnavailableOffline(resource: resource)
                    }
                    guard result.status == 0 else {
                        throw TeXEngineError.compilationFailed(
                            status: result.status,
                            message: Self.failureSummary(result.combinedOutput)
                        )
                    }
                    try Task.checkCancellation()
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
                    markCacheReady(for: job)
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

    private func cacheReadyMarkerURL(for job: TeXJob) -> URL {
        cacheDirectory.appendingPathComponent(
            ".clip-cache-ready-\(Self.version)-\(job.format.rawValue)",
            isDirectory: false
        )
    }

    private func isCacheReady(for job: TeXJob) -> Bool {
        FileManager.default.isReadableFile(atPath: cacheReadyMarkerURL(for: job).path)
    }

    private func markCacheReady(for job: TeXJob) {
        try? Data().write(to: cacheReadyMarkerURL(for: job), options: .atomic)
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

    static func cachedResourceMiss(in output: String) -> String? {
        let normalized = output.lowercased()
        guard normalized.contains("using only cached resource files") else { return nil }
        if normalized.contains("this bundle isn't cached") {
            return "The LaTeX package bundle"
        }
        if normalized.contains("tectonic-format-latex.tex") {
            return "The LaTeX format"
        }
        if normalized.contains("could not open format file")
            || normalized.contains("cannot open format file")
        {
            return "The LaTeX format"
        }

        let packagePattern =
            #"(?i)file\s+[`'\"]([^`'\"]+\.(?:sty|cls|clo|def|fd|cfg|fmt|ini|tfm|ofm|otf|ttf|pfb|enc|map|tec|ltx|lua|dat|pat))[`'\"]\s+not\s+found"#
        guard let expression = try? NSRegularExpression(pattern: packagePattern) else {
            return nil
        }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = expression.firstMatch(in: output, range: range),
            let resourceRange = Range(match.range(at: 1), in: output)
        else {
            return nil
        }
        return String(output[resourceRange])
    }

    static func requiresNetworkRetry(_ output: String) -> Bool {
        cachedResourceMiss(in: output) != nil
    }
}

private final class TeXEngineActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() {
        lock.lock()
        activeCount += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        activeCount -= 1
        let waiters = activeCount == 0 ? idleWaiters : []
        if activeCount == 0 { idleWaiters.removeAll() }
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if activeCount == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
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
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
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
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
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
        // Compiler diagnostics may contain a filename in a legacy encoding.
        // Preserve the rest of the log instead of erasing every diagnostic.
        return String(decoding: data, as: UTF8.self)
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
        let runningProcess: Process? = lock.withLock {
            guard let process, process.isRunning else { return nil }
            self.process = nil
            return process
        }
        guard let runningProcess else { return }
        kill(runningProcess.processIdentifier, SIGKILL)
        // Cache maintenance joins the outer compile task before deleting its
        // directory. Make cancellation deterministic by not returning until
        // the child can no longer write into that cache.
        runningProcess.waitUntilExit()
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
