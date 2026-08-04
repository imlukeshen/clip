import Foundation

public struct EngineID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let tectonic: Self = "tectonic"
    public static let systemTeX: Self = "system-tex"
}

public enum TeXFormat: String, Codable, Sendable, CaseIterable {
    case pdfLaTeX
    case xeLaTeX
    case luaLaTeX
}

public enum BibMode: String, Codable, Sendable, CaseIterable {
    case auto
    case biber
    case bibtex
    case none
}

public enum TeXPackageAccess: String, Codable, Sendable, CaseIterable {
    case cachedOnly
    case allowNetwork
}

public enum TeXCompileMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case onSave
    case manual
}

public enum TeXDiagnosticSeverity: String, Codable, Sendable, Equatable {
    case error
    case warning
    case information
}

public struct TeXDiagnostic: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var severity: TeXDiagnosticSeverity
    public var message: String
    public var file: String?
    public var line: Int?

    public init(
        id: UUID = UUID(),
        severity: TeXDiagnosticSeverity,
        message: String,
        file: String? = nil,
        line: Int? = nil
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
    }
}

public struct TeXJob: Sendable {
    public var mainFile: URL
    public var workingDirectory: URL
    public var projectFiles: [URL]
    public var sourceOverrides: [String: Data]
    public var format: TeXFormat
    public var synctex: Bool
    public var bibliography: BibMode
    public var timeout: Duration
    public var packageAccess: TeXPackageAccess
    public var bundleURL: URL?
    public var outputSizeLimit: Int64

    public init(
        mainFile: URL,
        workingDirectory: URL? = nil,
        projectFiles: [URL]? = nil,
        sourceOverrides: [String: Data] = [:],
        format: TeXFormat = .xeLaTeX,
        synctex: Bool = true,
        bibliography: BibMode = .auto,
        timeout: Duration = .seconds(120),
        packageAccess: TeXPackageAccess = .cachedOnly,
        bundleURL: URL? = nil,
        outputSizeLimit: Int64 = 500 * 1_024 * 1_024
    ) {
        let directory = workingDirectory ?? mainFile.deletingLastPathComponent()
        self.mainFile = mainFile.standardizedFileURL
        self.workingDirectory = directory.standardizedFileURL
        self.projectFiles = (projectFiles ?? [mainFile]).map(\.standardizedFileURL)
        self.sourceOverrides = sourceOverrides
        self.format = format
        self.synctex = synctex
        self.bibliography = bibliography
        self.timeout = timeout
        self.packageAccess = packageAccess
        self.bundleURL = bundleURL?.standardizedFileURL
        self.outputSizeLimit = outputSizeLimit
    }
}

public enum TeXEvent: Sendable, Equatable {
    case pass(Int, of: Int)
    case logLine(String)
    case diagnostic(TeXDiagnostic)
    case finished(pdf: URL, synctex: URL?)
}

public protocol TeXEngine: Sendable {
    var id: EngineID { get }
    var displayName: String { get }
    var isAvailable: Bool { get }
    func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error>
}

public enum TeXEngineError: Error, Sendable, Equatable {
    case unavailable
    case invalidMainFile
    case unsafeProjectEntry(String)
    case unsafeSource(String)
    case launchFailed(String)
    case compilationFailed(status: Int32, message: String)
    case timedOut
    case cancelled
    case missingOutput
    case outputTooLarge(limit: Int64)
}

extension TeXEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "No safe TeX engine is available."
        case .invalidMainFile:
            "The LaTeX main file is outside its project folder or is unavailable."
        case .unsafeProjectEntry(let path):
            "The project entry is unsafe and was not compiled: \(path)"
        case .unsafeSource(let reason):
            "The LaTeX source was refused: \(reason)"
        case .launchFailed(let message):
            "The TeX engine could not start: \(message)"
        case .compilationFailed(_, let message):
            message.isEmpty ? "LaTeX compilation failed." : message
        case .timedOut:
            "LaTeX compilation exceeded its time limit and was stopped."
        case .cancelled:
            "LaTeX compilation was cancelled."
        case .missingOutput:
            "The TeX engine finished without producing a PDF."
        case .outputTooLarge(let limit):
            "The compiled PDF exceeds Clip's \(limit / 1_024 / 1_024) MB safety limit."
        }
    }
}
