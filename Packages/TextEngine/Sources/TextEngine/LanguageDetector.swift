import CoreModel
import Foundation

/// Infers a file's highlighting language from its path and contents.
///
/// The resolution order matches the design: an explicit user choice wins (the
/// caller checks `languageIsExplicit` before asking here), then the file
/// extension, then a shebang line, then a small set of content heuristics.
/// Anything unrecognized resolves to ``LanguageID/plainText``.
public enum LanguageDetector {
    /// Detects the language for a file.
    ///
    /// - Parameters:
    ///   - path: The file's path or name; only its extension is consulted.
    ///   - contents: The decoded text, used for shebang and content fallbacks.
    ///     Pass `nil` when the bytes are not yet available to detect by name only.
    /// - Returns: The resolved language, or ``LanguageID/plainText`` if unknown.
    public static func detect(path: String, contents: String? = nil) -> LanguageID {
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let language = languagesByExtension[ext] {
            return language
        }
        // Extensionless files (Makefile, Dockerfile, dotfiles) key off the name.
        let name = (path as NSString).lastPathComponent.lowercased()
        if let language = languagesByFilename[name] {
            return language
        }
        guard let contents else { return .plainText }
        if let language = detectByShebang(contents) {
            return language
        }
        if let language = detectByContent(contents) {
            return language
        }
        return .plainText
    }

    /// Maps a lowercase file extension to a language.
    ///
    /// Several extensions intentionally collapse onto one grammar (`.h` → C,
    /// `.mjs`/`.cjs` → JavaScript) because Tree-sitter has no distinct grammar
    /// for them and the shared one highlights correctly.
    private static let languagesByExtension: [String: LanguageID] = [
        "md": .markdown, "markdown": .markdown, "mdown": .markdown,
        "tex": .latex, "latex": .latex, "sty": .latex, "cls": .latex,
        "swift": .swift,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript,
        "py": .python, "pyw": .python,
        "json": .json,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
        "html": .html, "htm": .html,
        "css": .css,
        "rs": .rust,
        "go": .go,
        "c": .c, "h": .c,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "java": .java,
        "sql": .sql,
        "sh": .bash, "bash": .bash, "zsh": .bash,
        "xml": .xml, "plist": .xml, "svg": .xml,
        "txt": .plainText, "text": .plainText,
    ]

    /// The lowercase file extensions the editor recognizes as text.
    ///
    /// A single source of truth shared by ingest — which routes these to the
    /// text workspace as `AssetKind.text` — and the language dropdown. Deriving
    /// it from ``detect(path:contents:)``'s own table keeps the two in step.
    public static var recognizedExtensions: Set<String> {
        Set(languagesByExtension.keys)
    }

    /// Maps a lowercase full filename to a language for extensionless files.
    private static let languagesByFilename: [String: LanguageID] = [
        "makefile": .bash,
        "dockerfile": .bash,
        ".bashrc": .bash, ".zshrc": .bash, ".profile": .bash,
    ]

    /// Resolves a language from a `#!` interpreter line.
    private static func detectByShebang(_ contents: String) -> LanguageID? {
        guard contents.hasPrefix("#!") else { return nil }
        let firstLine =
            contents
            .prefix(while: { $0 != "\n" })
            .lowercased()
        if firstLine.contains("python") { return .python }
        if firstLine.contains("bash") || firstLine.contains("/sh") || firstLine.contains("zsh") {
            return .bash
        }
        if firstLine.contains("node") { return .javascript }
        if firstLine.contains("swift") { return .swift }
        return nil
    }

    /// Applies the deliberately small, high-confidence content heuristic tier.
    private static func detectByContent(_ contents: String) -> LanguageID? {
        let prefix = String(contents.prefix(64 * 1024))
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\\documentclass") || trimmed.contains("\\documentclass{") {
            return .latex
        }
        if trimmed.hasPrefix("<?xml") {
            return .xml
        }
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        // Parsing is bounded so language detection cannot stall a large buffer.
        guard contents.utf8.count <= 1024 * 1024, let data = contents.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return nil }
        return .json
    }
}
