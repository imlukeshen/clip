import Darwin
import Foundation

/// Optional Office-output backend for the unsandboxed direct-download build.
public struct LibreOfficeBackend: ConversionBackend {
    public let capabilities: ConversionCapabilities
    private let processTimeout: Duration
    private let logSizeLimit: Int64

    public init(capabilities: ConversionCapabilities) {
        self.capabilities = capabilities
        self.processTimeout = .seconds(300)
        self.logSizeLimit = 8 * 1_024 * 1_024
    }

    init(
        capabilities: ConversionCapabilities,
        processTimeout: Duration,
        logSizeLimit: Int64
    ) {
        self.capabilities = capabilities
        self.processTimeout = processTimeout
        self.logSizeLimit = logSizeLimit
    }

    public var id: BackendID { .libreOffice }
    public var isAvailable: Bool { capabilities.isLibreOfficeAvailable }

    public func edges() -> [ConversionEdge] {
        guard isAvailable else { return [] }
        let officeWarning = [
            "Office layout may change. Review the converted document before sharing."
        ]
        return [
            ConversionEdge(
                from: .oneOf(ConversionFormats.writerInputs + [ConversionFormats.pdf]),
                to: ConversionFormats.docx,
                backend: id,
                implementation: .libreOffice,
                cost: .expensive,
                isLossless: false,
                warnings: officeWarning,
                supportedOptions: [.stripMetadata]
            ),
            ConversionEdge(
                from: .oneOf(ConversionFormats.spreadsheetInputs),
                to: ConversionFormats.xlsx,
                backend: id,
                implementation: .libreOffice,
                cost: .expensive,
                isLossless: false,
                warnings: officeWarning,
                supportedOptions: [.stripMetadata]
            ),
            ConversionEdge(
                from: .oneOf(
                    ConversionFormats.presentationInputs + [ConversionFormats.pdf]
                ),
                to: ConversionFormats.pptx,
                backend: id,
                implementation: .libreOffice,
                cost: .expensive,
                isLossless: false,
                warnings: officeWarning,
                supportedOptions: [.stripMetadata]
            ),
        ]
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        let process = LibreOfficeProcessBox()
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    continuation.yield(0)
                    try Task.checkCancellation()
                    guard self.isAvailable else {
                        throw ConversionError.backendUnavailable(
                            "LibreOffice is no longer available. Reinstall it or choose another format."
                        )
                    }
                    try await self.convert(
                        step,
                        input: input,
                        output: output,
                        process: process
                    )
                    try Task.checkCancellation()
                    continuation.yield(1)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ConversionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                    Task { await process.terminate() }
                }
            }
        }
    }

    private func convert(
        _ step: PlannedStep,
        input: URL,
        output: URL,
        process processBox: LibreOfficeProcessBox
    ) async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-libreoffice-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let profile = workspace.appendingPathComponent("profile", isDirectory: true)
        let outputFilter = try Self.outputFilter(for: step.to)
        let expected = workspace.appendingPathComponent(
            input.deletingPathExtension().lastPathComponent
        ).appendingPathExtension(step.to.preferredFilenameExtension)
        let standardOutputURL = workspace.appendingPathComponent("stdout.log")
        let standardErrorURL = workspace.appendingPathComponent("stderr.log")
        var arguments = [
            "-env:UserInstallation=\(profile.absoluteString)",
            "--headless",
            "--nologo",
            "--nodefault",
            "--nolockcheck",
            "--norestore",
        ]
        if step.from == ConversionFormats.pdf {
            arguments.append(
                step.to == ConversionFormats.docx
                    ? "--infilter=writer_pdf_import"
                    : "--infilter=impress_pdf_import"
            )
        }
        arguments.append(contentsOf: [
            "--convert-to", "\(step.to.preferredFilenameExtension):\(outputFilter)",
            "--outdir", workspace.path,
            input.path,
        ])
        let result = try await processBox.run(
            executableURL: capabilities.libreOfficeExecutable,
            arguments: arguments,
            standardOutputURL: standardOutputURL,
            standardErrorURL: standardErrorURL,
            timeout: processTimeout,
            logSizeLimit: logSizeLimit
        )
        try Task.checkCancellation()
        guard result.status == 0,
            FileManager.default.fileExists(atPath: expected.path)
        else {
            let detail =
                [result.errorText, result.outputText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                ?? "LibreOffice did not produce the requested Office document"
            throw ConversionError.conversionFailed(detail)
        }
        let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.moveItem(at: expected, to: temporary)
        try AtomicOutput.commit(temporary, to: output)
    }

    private static func outputFilter(for target: FormatID) throws -> String {
        if target == ConversionFormats.docx { return "Office Open XML Text" }
        if target == ConversionFormats.xlsx { return "Calc Office Open XML" }
        if target == ConversionFormats.pptx { return "Impress Office Open XML" }
        throw ConversionError.unsupported("LibreOffice cannot write this target format")
    }
}

private actor LibreOfficeProcessBox {
    private var process: Process?

    func run(
        executableURL: URL,
        arguments: [String],
        standardOutputURL: URL,
        standardErrorURL: URL,
        timeout: Duration,
        logSizeLimit: Int64
    ) async throws -> (status: Int32, outputText: String, errorText: String) {
        _ = FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
        let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        let standardError = try FileHandle(forWritingTo: standardErrorURL)
        defer {
            try? standardOutput.close()
            try? standardError.close()
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        self.process = process
        defer { self.process = nil }
        let status = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try await Self.launchAndWait(process)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ConversionError.conversionFailed(
                        "LibreOffice exceeded its safety time limit and was stopped."
                    )
                }
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        try Self.validateLogSize(
                            outputURL: standardOutputURL,
                            errorURL: standardErrorURL,
                            limit: logSizeLimit
                        )
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                do {
                    guard let status = try await group.next() else {
                        throw ConversionError.conversionFailed(
                            "LibreOffice ended without reporting a status."
                        )
                    }
                    group.cancelAll()
                    return status
                } catch {
                    Self.kill(process)
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            Self.kill(process)
        }
        try standardOutput.synchronize()
        try standardError.synchronize()
        try Self.validateLogSize(
            outputURL: standardOutputURL,
            errorURL: standardErrorURL,
            limit: logSizeLimit
        )
        let outputText = try Self.readLog(at: standardOutputURL, limit: logSizeLimit)
        let errorText = try Self.readLog(at: standardErrorURL, limit: logSizeLimit)
        return (status, outputText, errorText)
    }

    private nonisolated static func launchAndWait(_ process: Process) async throws -> Int32 {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try Task.checkCancellation()
                try process.run()
                if Task.isCancelled { kill(process) }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private nonisolated static func validateLogSize(
        outputURL: URL,
        errorURL: URL,
        limit: Int64
    ) throws {
        guard limit >= 0 else { throw oversizedLogError }
        let outputSize = try logSize(at: outputURL)
        let errorSize = try logSize(at: errorURL)
        guard outputSize <= limit, errorSize <= limit - outputSize else {
            throw oversizedLogError
        }
    }

    private nonisolated static func logSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private nonisolated static func readLog(at url: URL, limit: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let safeLimit = min(limit, Int64(Int.max - 1))
        guard safeLimit >= 0 else { throw oversizedLogError }
        let data = try handle.read(upToCount: Int(safeLimit) + 1) ?? Data()
        guard Int64(data.count) <= limit else { throw oversizedLogError }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated static var oversizedLogError: ConversionError {
        .conversionFailed("LibreOffice produced too much diagnostic output and was stopped.")
    }

    private nonisolated static func kill(_ process: Process) {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func terminate() {
        guard process?.isRunning == true else { return }
        process?.terminate()
    }
}
