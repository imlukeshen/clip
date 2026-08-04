import Foundation

/// The phantom tag for a text-file identifier.
public enum FileTag: Sendable {}

/// Identifies one file within a ``TextDocument``.
public typealias FileID = TypedID<FileTag>

/// How a text file's lines are terminated on disk.
///
/// Detected on open and shown in the status bar; never rewritten silently.
public enum LineEnding: String, Codable, Sendable, Equatable, CaseIterable {
    /// Unix line feed (`\n`).
    case lf
    /// Windows carriage return + line feed (`\r\n`).
    case crlf
    /// Classic Mac carriage return (`\r`).
    case cr
    /// A file that mixes more than one terminator.
    case mixed
}

/// The bounded set of text encodings the editor detects and persists.
///
/// Kept a closed enum rather than storing a raw `String.Encoding` so a
/// ``TextDocument`` round-trips through JSON deterministically. The detection
/// order in the editor is UTF-8, then UTF-16, then ISO Latin-1 as a lossless
/// single-byte catch-all.
public enum TextEncoding: String, Codable, Sendable, Equatable, CaseIterable {
    /// UTF-8, the default for new and most existing files.
    case utf8
    /// UTF-16 with a byte-order mark.
    case utf16
    /// Big-endian UTF-16.
    case utf16BigEndian
    /// Little-endian UTF-16.
    case utf16LittleEndian
    /// ISO Latin-1 (ISO 8859-1); decodes any byte sequence without failing.
    case isoLatin1
    /// Windows Latin-1 (code page 1252).
    case windowsLatin1
    /// Mac OS Roman.
    case macRoman
    /// 7-bit ASCII.
    case ascii

    /// The Foundation encoding this case maps to.
    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16: .utf16
        case .utf16BigEndian: .utf16BigEndian
        case .utf16LittleEndian: .utf16LittleEndian
        case .isoLatin1: .isoLatin1
        case .windowsLatin1: .windowsCP1252
        case .macRoman: .macOSRoman
        case .ascii: .ascii
        }
    }
}

/// A byte-order mark that was present when a text file was opened.
public enum TextByteOrderMark: String, Codable, Sendable, Equatable {
    /// UTF-8 signature (`EF BB BF`).
    case utf8
    /// UTF-16 little-endian signature (`FF FE`).
    case utf16LittleEndian
    /// UTF-16 big-endian signature (`FE FF`).
    case utf16BigEndian
}

/// Names the highlighting grammar and dropdown entry for a file's language.
///
/// A stable lowercase identifier such as `swift` or `typescript`, not a UUID.
/// The 19 values with a real Tree-sitter grammar are exposed as static members;
/// anything else falls back to the regex highlighter.
public struct LanguageID: RawRepresentable, Codable, Sendable, Hashable {
    /// The lowercase language identifier.
    public let rawValue: String

    /// Creates a language identifier, canonicalizing its casing.
    public init(rawValue: String) {
        self.rawValue = rawValue.lowercased()
    }
}

extension LanguageID {
    /// No grammar; plain, unhighlighted text.
    public static let plainText = LanguageID(rawValue: "text")
    /// Markdown.
    public static let markdown = LanguageID(rawValue: "markdown")
    /// LaTeX.
    public static let latex = LanguageID(rawValue: "latex")
    /// Swift.
    public static let swift = LanguageID(rawValue: "swift")
    /// JavaScript.
    public static let javascript = LanguageID(rawValue: "javascript")
    /// TypeScript.
    public static let typescript = LanguageID(rawValue: "typescript")
    /// Python.
    public static let python = LanguageID(rawValue: "python")
    /// JSON.
    public static let json = LanguageID(rawValue: "json")
    /// YAML.
    public static let yaml = LanguageID(rawValue: "yaml")
    /// TOML.
    public static let toml = LanguageID(rawValue: "toml")
    /// HTML.
    public static let html = LanguageID(rawValue: "html")
    /// CSS.
    public static let css = LanguageID(rawValue: "css")
    /// Rust.
    public static let rust = LanguageID(rawValue: "rust")
    /// Go.
    public static let go = LanguageID(rawValue: "go")
    /// C.
    public static let c = LanguageID(rawValue: "c")
    /// C++.
    public static let cpp = LanguageID(rawValue: "cpp")
    /// Java.
    public static let java = LanguageID(rawValue: "java")
    /// SQL.
    public static let sql = LanguageID(rawValue: "sql")
    /// Bash.
    public static let bash = LanguageID(rawValue: "bash")
    /// XML.
    public static let xml = LanguageID(rawValue: "xml")

    /// The languages that ship with a bundled Tree-sitter grammar.
    public static let treeSitterGrammars: [LanguageID] = [
        .markdown, .latex, .swift, .javascript, .typescript, .python, .json,
        .yaml, .toml, .html, .css, .rust, .go, .c, .cpp, .java, .sql, .bash, .xml,
    ]

    /// Whether this language has a real grammar rather than the regex fallback.
    public var hasTreeSitterGrammar: Bool {
        LanguageID.treeSitterGrammars.contains(self)
    }
}

/// Per-editor display preferences that persist with the document.
public struct EditorSettings: Codable, Sendable, Equatable {
    /// Whether long lines wrap to the view width.
    public var softWrap: Bool
    /// The number of spaces a tab represents, `1...16`.
    public var tabWidth: Int
    /// The editor font size in points.
    public var fontSize: Double
    /// Whether whitespace and line endings render as glyphs.
    public var showInvisibles: Bool

    /// Creates editor settings.
    ///
    /// - Parameters:
    ///   - softWrap: Whether long lines wrap. Defaults to `true`.
    ///   - tabWidth: Spaces per tab, `1...16`. Defaults to `4`.
    ///   - fontSize: Font size in points. Defaults to `13`.
    ///   - showInvisibles: Whether to render whitespace. Defaults to `false`.
    public init(
        softWrap: Bool = true,
        tabWidth: Int = 4,
        fontSize: Double = 13,
        showInvisibles: Bool = false
    ) {
        self.softWrap = softWrap
        self.tabWidth = tabWidth
        self.fontSize = fontSize
        self.showInvisibles = showInvisibles
    }
}

/// One file in a ``TextDocument``. A standalone buffer has a single file; a
/// LaTeX project has one per source file in the folder.
public struct TextFile: Codable, Sendable, Equatable, Identifiable {
    /// The file's identifier within its document.
    public var id: FileID
    /// The backing library asset, or `nil` for an unsaved scratch buffer.
    public var assetID: AssetID?
    /// The file's path relative to the document root.
    public var relativePath: String
    /// The resolved or user-chosen highlighting language.
    public var language: LanguageID
    /// `true` when the user picked the language; suppresses re-detection.
    public var languageIsExplicit: Bool
    /// The text encoding detected on open.
    public var encoding: TextEncoding
    /// How the file's lines are terminated.
    public var lineEnding: LineEnding
    /// The original byte-order mark, retained so saving does not silently remove it.
    public var byteOrderMark: TextByteOrderMark?

    /// Creates a text file record.
    ///
    /// - Parameters:
    ///   - id: The file identifier. Generated when omitted.
    ///   - assetID: The backing asset, or `nil` for a scratch buffer.
    ///   - relativePath: The path relative to the document root.
    ///   - language: The highlighting language. Defaults to plain text.
    ///   - languageIsExplicit: Whether the user chose the language.
    ///   - encoding: The text encoding. Defaults to UTF-8.
    ///   - lineEnding: The line terminator. Defaults to line feed.
    public init(
        id: FileID = .generate(),
        assetID: AssetID? = nil,
        relativePath: String,
        language: LanguageID = .plainText,
        languageIsExplicit: Bool = false,
        encoding: TextEncoding = .utf8,
        lineEnding: LineEnding = .lf,
        byteOrderMark: TextByteOrderMark? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.relativePath = relativePath
        self.language = language
        self.languageIsExplicit = languageIsExplicit
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.byteOrderMark = byteOrderMark
    }
}

/// The document-level mutations of a text editor.
///
/// Content edits — typing, paste, find/replace — deliberately do **not** flow
/// through here; they use `NSTextView`'s native `UndoManager`, the one
/// documented exception to invariant I4, recorded in
/// `docs/adr/0008-text-editing-uses-native-undo.md`. Only structural operations
/// on the file set are patches.
///
/// `addFile` and `setLanguage` carry more than the doc's illustrative
/// signatures — an insertion index and the explicit-language flag respectively —
/// because invariant I3 requires each patch's inverse to restore the document
/// exactly, including file order and whether the language was user-chosen.
public enum TextPatch: DocumentPatch {
    /// Inserts a file at an index. Inverse of ``removeFile(_:)``.
    case addFile(TextFile, atIndex: Int)
    /// Removes a file by identifier. Inverse of ``addFile(_:atIndex:)``.
    case removeFile(FileID)
    /// Sets the LaTeX root file, or clears it with `nil`.
    case setMainFile(FileID?)
    /// Sets a file's language and whether the choice was explicit.
    case setLanguage(FileID, LanguageID, explicit: Bool)
    /// Replaces the editor settings.
    case setSettings(EditorSettings)
    /// Records the line ending used by one file after an explicit normalization.
    case setLineEnding(FileID, LineEnding)
    /// Records the encoding and byte-order mark detected for one file.
    case setEncoding(FileID, TextEncoding, byteOrderMark: TextByteOrderMark?)
    /// Changes a file's relative path.
    case renameFile(FileID, String)
}

/// A non-destructive text or code document: one or more files, a designated
/// LaTeX root, and shared editor settings.
///
/// Conforms to ``EditableDocument`` so document-level structure changes share
/// the one mutation path (I4) and every patch is exactly invertible (I3).
public struct TextDocument: EditableDocument {
    /// The newest schema version this build writes.
    public static let currentSchemaVersion = 1

    /// The schema version the document was encoded with.
    public var schemaVersion: Int
    /// The document identifier.
    public var id: DocumentID
    /// The files in the document, in display order.
    public var files: [TextFile]
    /// The LaTeX root file, or `nil` for a single-file document.
    public var mainFileID: FileID?
    /// Shared editor display settings.
    public var settings: EditorSettings

    /// Creates a validated text document.
    ///
    /// - Parameters:
    ///   - schemaVersion: The encoding schema version.
    ///   - id: The document identifier. Generated when omitted.
    ///   - files: The document's files, in display order.
    ///   - mainFileID: The LaTeX root, or `nil`.
    ///   - settings: The editor settings.
    /// - Throws: ``TextDocumentError`` or `ModelError` if the document is invalid.
    public init(
        schemaVersion: Int = TextDocument.currentSchemaVersion,
        id: DocumentID = .generate(),
        files: [TextFile],
        mainFileID: FileID? = nil,
        settings: EditorSettings = EditorSettings()
    ) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.files = files
        self.mainFileID = mainFileID
        self.settings = settings
        try validate()
    }

    @discardableResult
    public mutating func apply(_ patch: TextPatch) throws -> TextPatch {
        var candidate = self
        let inverse = try candidate.applyUnchecked(patch)
        try candidate.validate()
        self = candidate
        return inverse
    }

    public func validate() throws {
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw ModelError.schemaTooNew(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        var ids = Set<FileID>()
        var paths = Set<String>()
        for file in files {
            guard ids.insert(file.id).inserted else {
                throw TextDocumentError.duplicateFile(file.id)
            }
            guard !file.relativePath.isEmpty else {
                throw TextDocumentError.emptyPath(file.id)
            }
            guard paths.insert(file.relativePath).inserted else {
                throw TextDocumentError.duplicatePath(file.relativePath)
            }
        }
        if let mainFileID, !ids.contains(mainFileID) {
            throw TextDocumentError.mainFileNotFound(mainFileID)
        }
        guard (1...16).contains(settings.tabWidth) else {
            throw TextDocumentError.invalidSettings
        }
        guard settings.fontSize.isFinite, settings.fontSize > 0 else {
            throw TextDocumentError.invalidSettings
        }
    }

    private mutating func applyUnchecked(_ patch: TextPatch) throws -> TextPatch {
        switch patch {
        case .addFile(let file, let index):
            guard !files.contains(where: { $0.id == file.id }) else {
                throw TextDocumentError.duplicateFile(file.id)
            }
            guard (0...files.count).contains(index) else {
                throw TextDocumentError.indexOutOfRange(index, count: files.count)
            }
            files.insert(file, at: index)
            return .removeFile(file.id)

        case .removeFile(let id):
            guard let index = files.firstIndex(where: { $0.id == id }) else {
                throw TextDocumentError.fileNotFound(id)
            }
            let file = files.remove(at: index)
            return .addFile(file, atIndex: index)

        case .setMainFile(let id):
            let previous = mainFileID
            mainFileID = id
            return .setMainFile(previous)

        case .setLanguage(let id, let language, let explicit):
            guard let index = files.firstIndex(where: { $0.id == id }) else {
                throw TextDocumentError.fileNotFound(id)
            }
            let previousLanguage = files[index].language
            let previousExplicit = files[index].languageIsExplicit
            files[index].language = language
            files[index].languageIsExplicit = explicit
            return .setLanguage(id, previousLanguage, explicit: previousExplicit)

        case .setSettings(let settings):
            let previous = self.settings
            self.settings = settings
            return .setSettings(previous)

        case .setLineEnding(let id, let lineEnding):
            guard let index = files.firstIndex(where: { $0.id == id }) else {
                throw TextDocumentError.fileNotFound(id)
            }
            let previous = files[index].lineEnding
            files[index].lineEnding = lineEnding
            return .setLineEnding(id, previous)

        case .setEncoding(let id, let encoding, let byteOrderMark):
            guard let index = files.firstIndex(where: { $0.id == id }) else {
                throw TextDocumentError.fileNotFound(id)
            }
            let previousEncoding = files[index].encoding
            let previousByteOrderMark = files[index].byteOrderMark
            files[index].encoding = encoding
            files[index].byteOrderMark = byteOrderMark
            return .setEncoding(
                id,
                previousEncoding,
                byteOrderMark: previousByteOrderMark
            )

        case .renameFile(let id, let path):
            guard let index = files.firstIndex(where: { $0.id == id }) else {
                throw TextDocumentError.fileNotFound(id)
            }
            let previous = files[index].relativePath
            files[index].relativePath = path
            return .renameFile(id, previous)
        }
    }
}

/// Failures produced while validating or mutating a ``TextDocument``.
public enum TextDocumentError: Error, Sendable, Equatable {
    /// Two files share the same identifier.
    case duplicateFile(FileID)
    /// A referenced file does not exist.
    case fileNotFound(FileID)
    /// An insertion or removal index is outside the file list.
    case indexOutOfRange(Int, count: Int)
    /// Two files share the same relative path.
    case duplicatePath(String)
    /// A file has an empty relative path.
    case emptyPath(FileID)
    /// The designated main file is not in the document.
    case mainFileNotFound(FileID)
    /// The editor settings are out of range.
    case invalidSettings
}
