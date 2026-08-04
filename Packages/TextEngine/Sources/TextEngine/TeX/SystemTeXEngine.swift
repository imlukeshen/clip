import Foundation

/// Optional direct-build adapter for a user's MacTeX installation.
///
/// Callers must explicitly enable this adapter. App Store builds pass `false`
/// so the presence of a host installation can never make process execution
/// appear available in that distribution channel.
public struct SystemTeXEngine: TeXEngine {
    public static let defaultExecutableURL = URL(
        fileURLWithPath: "/Library/TeX/texbin/latexmk"
    )

    public let id: EngineID = .systemTeX
    public let displayName = "System TeX"
    public let executableURL: URL
    public let isEnabled: Bool

    public init(
        executableURL: URL = Self.defaultExecutableURL,
        isEnabled: Bool
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.isEnabled = isEnabled
    }

    public var isAvailable: Bool {
        isEnabled && FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard isAvailable else {
                    continuation.finish(throwing: TeXEngineError.unavailable)
                    return
                }
                do {
                    let workspace = try TeXWorkspaceSandbox.prepare(job)
                    defer { workspace.remove() }
                    continuation.yield(.pass(1, of: 1))
                    let result = try await TeXProcessController().run(
                        executableURL: executableURL,
                        arguments: arguments(for: job, workspace: workspace),
                        currentDirectory: workspace.source,
                        environment: environment,
                        timeout: job.timeout,
                        logDirectory: workspace.root
                    )
                    for line in result.combinedOutput.components(separatedBy: .newlines)
                    where !line.isEmpty {
                        continuation.yield(.logLine(line))
                    }
                    guard result.status == 0 else {
                        throw TeXEngineError.compilationFailed(
                            status: result.status,
                            message: TectonicEngine.failureSummary(result.combinedOutput)
                        )
                    }
                    let name = URL(fileURLWithPath: workspace.mainRelativePath)
                        .deletingPathExtension().lastPathComponent
                    let results = try TectonicEngine.copyValidatedResults(
                        pdf: workspace.output.appendingPathComponent("\(name).pdf"),
                        synctex: job.synctex
                            ? workspace.output.appendingPathComponent("\(name).synctex.gz") : nil,
                        sizeLimit: job.outputSizeLimit
                    )
                    try Task.checkCancellation()
                    continuation.yield(.finished(pdf: results.pdf, synctex: results.synctex))
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

    private func arguments(for job: TeXJob, workspace: TeXWorkspaceSandbox) -> [String] {
        var values = [
            engineFlag(job.format),
            "-no-shell-escape",
            "-interaction=nonstopmode",
            "-halt-on-error",
            "-file-line-error",
            "-outdir=\(workspace.output.path)",
        ]
        if job.synctex { values.append("-synctex=1") }
        values.append(workspace.mainRelativePath)
        return values
    }

    private var environment: [String: String] {
        [
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "PATH": "/Library/TeX/texbin:/usr/bin:/bin",
            "openin_any": "p",
            "openout_any": "p",
            "shell_escape": "f",
        ]
    }

    private func engineFlag(_ format: TeXFormat) -> String {
        switch format {
        case .pdfLaTeX: "-pdf"
        case .xeLaTeX: "-xelatex"
        case .luaLaTeX: "-lualatex"
        }
    }
}
