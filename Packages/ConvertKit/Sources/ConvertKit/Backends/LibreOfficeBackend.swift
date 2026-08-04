import Foundation

/// Optional Office-output backend for the unsandboxed direct-download build.
public struct LibreOfficeBackend: ConversionBackend {
    public let capabilities: ConversionCapabilities

    public init(capabilities: ConversionCapabilities) {
        self.capabilities = capabilities
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
            standardErrorURL: standardErrorURL
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
        standardErrorURL: URL
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
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try standardOutput.synchronize()
        try standardError.synchronize()
        let outputText =
            String(
                data: try Data(contentsOf: standardOutputURL),
                encoding: .utf8
            ) ?? ""
        let errorText =
            String(
                data: try Data(contentsOf: standardErrorURL),
                encoding: .utf8
            ) ?? ""
        return (status, outputText, errorText)
    }

    func terminate() {
        guard process?.isRunning == true else { return }
        process?.terminate()
    }
}
