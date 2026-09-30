import CoreModel
import Foundation

/// One run of an editor buffer, exactly as it appears in the editor.
public struct CodeRunRequest: Sendable, Equatable {
    /// The buffer's language, which picks the toolchain.
    public let language: LanguageID
    /// The program to run, including unsaved edits.
    public var source: String
    /// The name shown in errors, such as `solver.py`. Always a bare file name
    /// with the language's extension, whatever the editor called the buffer.
    public let fileName: String
    /// The folder the program runs in, so relative paths and sibling imports
    /// resolve beside the file. `nil` for a scratch buffer with no folder.
    public var workingDirectory: URL?
    /// The longest the build and run together may take before being stopped.
    public var timeout: Duration

    /// Creates a run request.
    public init(
        language: LanguageID,
        source: String,
        fileName: String,
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(60)
    ) {
        self.language = language
        self.source = source
        self.fileName = Self.scriptName(for: fileName, language: language)
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    /// A bare file name whose extension the language's toolchain accepts.
    private static func scriptName(for fileName: String, language: LanguageID) -> String {
        let name = (fileName.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else {
            return "main.\(LanguageDetector.preferredExtension(for: language))"
        }
        return LanguageDetector.fileName(name, matching: language)
    }
}
