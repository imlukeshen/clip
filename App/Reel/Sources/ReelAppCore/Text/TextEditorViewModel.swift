import AppKit
import CoreModel
import Darwin
import Dispatch
import Foundation
import LibraryStore
import Observation
import TextEngine

public enum TeXCompilationState: Sendable, Equatable {
    case idle
    case compiling
    case succeeded
    case paused(String)
    case failed(String)
}

public enum TextEditorCommandError: Error, Sendable, Equatable, LocalizedError {
    case fileNotFound(String)
    case invalidLineRange(Int, Int)
    case overlappingLineEdits
    case unsupportedLineEnding(String)
    case noFormattingRequested

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let file): return "The text project has no file named \(file)."
        case .invalidLineRange(let start, let end):
            return "The line range \(start)–\(end) is outside the active file."
        case .overlappingLineEdits: return "Text line edits must not overlap."
        case .unsupportedLineEnding(let value):
            return "Line ending must be lf, crlf, or cr; received \(value)."
        case .noFormattingRequested: return "No text formatting change was requested."
        }
    }
}

/// Drives one open text or code document.
///
/// This view model is deliberately split from the patch-graph editors. Its
/// **content** — the characters in the buffer — is owned by the `NSTextView` and
/// its native `UndoManager`; the view binds to ``text`` and the AppKit undo stack
/// handles typing, paste, and find/replace (invariant I4's one documented
/// exception, ADR-0008). Only **document-level** structure — languages, the
/// LaTeX main file, editor settings — flows through ``TextPatch`` and shares the
/// same `UndoManager`, so the two interleave in one coherent undo history.
///
/// Persistence has two halves that mirror where text lives (design §2.2):
/// - The structural ``TextDocument`` is written to a `.reeltext` overlay in
///   `.reel/text/`, exactly like the PDF and image editors persist their models.
/// - The buffer contents are saved **in place**: to the library `Media/` file for
///   a saved asset (via the writable-text exception, ADR-0009), or to
///   `.reel/scratch/` for an unnamed scratch buffer. Both autosave on a debounce.
@MainActor
@Observable
public final class TextEditorViewModel {
    /// The structural document: files, languages, main file, settings.
    public private(set) var document: TextDocument
    /// The editable buffer bound to the text view. Content edits mutate this
    /// directly through AppKit; they do not go through ``TextPatch``.
    public var text: String {
        didSet {
            guard text != oldValue else { return }
            if isDetached { hasSavedDetachedCopy = false }
            guard !isApplyingExternalText else { return }
            textBuffers[activeFileID] = text
            rebuildTeXProjectAnalysis()
            isDirty = true
            dirtyFileIDs.insert(activeFileID)
            scheduleContentAutosave()
            scheduleTeXCompilation()
        }
    }
    /// The file currently shown in the editor.
    public private(set) var activeFileID: FileID
    /// A transient status line message.
    public private(set) var notice: String?
    /// Whether the buffer has unsaved changes since the last content save.
    public private(set) var isDirty = false
    /// Whether wrapping is suppressed to keep a pathological line responsive.
    public private(set) var isSoftWrapSuppressed = false
    /// Whether the buffer is protected from editing after a very large paste.
    public private(set) var isReadOnly = false
    /// The disk version awaiting a choice because the local buffer is dirty.
    public private(set) var pendingExternalContents: LoadedTextFile?
    /// Whether the backing file disappeared while its buffer was open.
    public private(set) var isDetached = false
    /// Whether the current detached contents have been copied somewhere safe.
    public private(set) var hasSavedDetachedCopy = false
    /// Current LaTeX compilation state. A failed build does not clear the last PDF.
    public private(set) var texCompilationState: TeXCompilationState = .idle
    /// Most recent successful PDF, retained while a later compile fails.
    public private(set) var texPDFURL: URL?
    /// Most recent SyncTeX sidecar, consumed by T4 source navigation.
    public private(set) var texSyncTeXURL: URL?
    /// Parsed source/PDF map from the most recent successful build.
    public private(set) var texSyncTeXIndex: SyncTeXIndex?
    /// Complete engine output. T4 adds structured presentation on top of this log.
    public private(set) var texLog = ""
    /// Parsed diagnostics emitted by the engine.
    public private(set) var texDiagnostics: [TeXDiagnostic] = []
    /// Whether the editor is waiting for the one-time package-network choice.
    public private(set) var needsTeXPackageConsent = false
    /// Automatic, on-save, or manual scheduling.
    public private(set) var texCompileMode: TeXCompileMode
    /// `nil` until the user chooses whether Tectonic may fetch packages.
    public private(set) var texPackageAccess: TeXPackageAccess?
    /// Dependency graph for the active LaTeX folder.
    public private(set) var texProjectAnalysis: TeXProjectAnalysis?

    /// The source file on disk, or `nil` for an unsaved scratch buffer.
    public var sourceURL: URL? { sourceURLs[activeFileID] }
    /// The undo manager shared by the text view and document-level patches.
    public let undoManager = UndoManager()

    /// Recomputes the content hash for an in-place save, matching ingest's scheme.
    private let hashData: @Sendable (Data) -> String
    /// Persists the structural document overlay (`.reel/text/*.reeltext`).
    private let persistStructure: @Sendable (TextDocument) async throws -> Void
    /// Persists the buffer contents to their on-disk home (library file or scratch).
    private let persistContents: @Sendable (FileID, Data, String) async throws -> Void
    private let sourceURLs: [FileID: URL]
    private let projectFileURLs: [String: URL]
    private var textBuffers: [FileID: String]
    private var dirtyFileIDs: Set<FileID> = []

    private var structureTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var externalReloadTask: Task<Void, Never>?
    private var fileMonitor: TextFileMonitor?
    private var isApplyingExternalText = false
    @ObservationIgnored private var texEngine: (any TeXEngine)?
    private var texCompileTask: Task<Void, Never>?
    private var texCompileGeneration = UUID()
    private var texSuccessfulSources: [FileID: String]?
    private let texPreferences: UserDefaults

    /// The debounce before an edited buffer autosaves, per design §2.2 (2 s).
    private let autosaveInterval: Duration = .seconds(2)

    /// Creates a text editor view model.
    ///
    /// - Parameters:
    ///   - document: The structural document to edit.
    ///   - text: The initial buffer contents.
    ///   - activeFileID: The file to display; defaults to the first file.
    ///   - sourceURL: The on-disk file, or `nil` for a scratch buffer.
    ///   - hashingWith: Computes the content hash for an in-place save.
    ///   - persistingStructure: Writes the `.reeltext` overlay.
    ///   - persistingContents: Writes the buffer bytes and their hash to disk.
    public convenience init(
        document: TextDocument,
        text: String,
        activeFileID: FileID? = nil,
        sourceURL: URL?,
        hashingWith hashData: @escaping @Sendable (Data) -> String,
        persistingStructure: @escaping @Sendable (TextDocument) async throws -> Void,
        persistingContents persistSingleContents:
            @escaping @Sendable (Data, String) async throws -> Void,
        texPreferences: UserDefaults = .standard
    ) {
        let selected = activeFileID ?? document.files[0].id
        self.init(
            document: document,
            contents: [selected: text],
            activeFileID: selected,
            sourceURLs: sourceURL.map { [selected: $0] } ?? [:],
            projectFileURLs: sourceURL.map {
                [
                    document.files.first(where: { $0.id == selected })?.relativePath
                        ?? $0.lastPathComponent: $0
                ]
            } ?? [:],
            hashingWith: hashData,
            persistingStructure: persistingStructure,
            persistingContents: { _, data, hash in
                try await persistSingleContents(data, hash)
            },
            texPreferences: texPreferences
        )
    }

    /// Creates an editor over every text file in one LaTeX project folder.
    public init(
        document: TextDocument,
        contents: [FileID: String],
        activeFileID: FileID,
        sourceURLs: [FileID: URL],
        projectFileURLs: [String: URL],
        hashingWith hashData: @escaping @Sendable (Data) -> String,
        persistingStructure: @escaping @Sendable (TextDocument) async throws -> Void,
        persistingContents: @escaping @Sendable (FileID, Data, String) async throws -> Void,
        texPreferences: UserDefaults = .standard
    ) {
        self.document = document
        self.text = contents[activeFileID] ?? ""
        self.activeFileID = activeFileID
        self.sourceURLs = sourceURLs
        self.projectFileURLs = projectFileURLs
        self.textBuffers = contents
        self.hashData = hashData
        self.persistStructure = persistingStructure
        self.persistContents = persistingContents
        self.texPreferences = texPreferences
        self.texCompileMode =
            texPreferences.string(forKey: "clip.tex.compileMode")
            .flatMap(TeXCompileMode.init(rawValue:)) ?? .automatic
        self.texPackageAccess =
            texPreferences.string(forKey: "clip.tex.packageAccess")
            .flatMap(TeXPackageAccess.init(rawValue:))
        rebuildTeXProjectAnalysis()
    }

    /// The file record currently being edited.
    public var activeFile: TextFile? {
        document.files.first { $0.id == activeFileID }
    }

    /// The highlighting language of the active file.
    public var language: LanguageID {
        activeFile?.language ?? .plainText
    }

    /// The shared editor display settings.
    public var settings: EditorSettings {
        document.settings
    }

    public var mainFile: TextFile? {
        guard let id = document.mainFileID else { return nil }
        return document.files.first { $0.id == id }
    }

    public func isReachableFromMain(_ file: TextFile) -> Bool {
        texProjectAnalysis?.reachableFiles.contains(file.relativePath) ?? true
    }

    /// Starts editor-owned background work.
    public func start() {
        startFileMonitor()
        scheduleTeXCompilation()
    }

    /// Stops background work and flushes any dirty content before closing.
    public func stop() {
        structureTask?.cancel()
        contentTask?.cancel()
        cleanupTask?.cancel()
        externalReloadTask?.cancel()
        texCompileTask?.cancel()
        fileMonitor?.cancel()
        fileMonitor = nil
        removeTeXResults()
        // A pending edit must not be lost when the editor closes.
        flushContentAutosave()
    }

    // MARK: - Document-level operations (patches)

    /// Applies a document-level patch and registers its inverse for undo.
    public func perform(_ patch: TextPatch, actionName: String) {
        do {
            let inverse = try document.apply(patch)
            registerUndo(inverse, actionName: actionName)
            undoManager.setActionName(actionName)
            rebuildTeXProjectAnalysis()
            persistStructureNow()
        } catch {
            notice = "That change could not be applied."
        }
    }

    /// Sets the active file's highlighting language as an explicit user choice.
    public func setLanguage(_ language: LanguageID) {
        guard let activeFile, activeFile.language != language else { return }
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        perform(
            .setLanguage(activeFileID, language, explicit: true),
            actionName: "Set Language"
        )
        if sourceURL == nil,
            Self.isDefaultScratchName(activeFile.relativePath),
            let pathExtension = Self.preferredScratchExtension(for: language)
        {
            perform(
                .renameFile(activeFileID, "Untitled.\(pathExtension)"),
                actionName: "Set Language"
            )
        }
        rebuildTeXProjectAnalysis()
        if language == .latex {
            scheduleTeXCompilation()
        } else {
            cancelTeXCompilation(resetState: true)
        }
    }

    /// Switches the visible buffer without discarding pending edits in the old file.
    public func selectFile(_ id: FileID) {
        guard id != activeFileID, document.files.contains(where: { $0.id == id }) else { return }
        guard pendingExternalContents == nil else {
            notice = "Resolve the file change before switching project files."
            return
        }
        guard !isDetached || hasSavedDetachedCopy else {
            notice = "Save a copy of this detached file before switching project files."
            return
        }
        contentTask?.cancel()
        cleanupTask?.cancel()
        if isDirty { writeContents() }
        textBuffers[activeFileID] = text
        fileMonitor?.cancel()
        fileMonitor = nil
        activeFileID = id
        pendingExternalContents = nil
        isDetached = false
        hasSavedDetachedCopy = false
        isApplyingExternalText = true
        text = textBuffers[id] ?? ""
        isApplyingExternalText = false
        isDirty = dirtyFileIDs.contains(id)
        if isDirty { scheduleContentAutosave() }
        undoManager.removeAllActions()
        startFileMonitor()
    }

    public func selectFile(relativePath: String) {
        guard let file = projectFile(matching: relativePath) else { return }
        selectFile(file.id)
    }

    /// Persists a user override for the project root file.
    public func setMainFile(_ id: FileID) {
        guard
            let file = document.files.first(where: { $0.id == id }),
            Self.isTeXSource(file.relativePath),
            document.mainFileID != id
        else {
            return
        }
        perform(.setMainFile(id), actionName: "Set Main LaTeX File")
        rebuildTeXProjectAnalysis()
        scheduleTeXCompilation()
    }

    /// Replaces the shared editor settings.
    public func updateSettings(_ settings: EditorSettings) {
        guard document.settings != settings else { return }
        perform(.setSettings(settings), actionName: "Editor Settings")
    }

    /// Undoes the latest content or document-setting edit.
    public func undo() { undoManager.undo() }
    /// Redoes the latest undone content or document-setting edit.
    public func redo() { undoManager.redo() }

    /// Clears the transient editor notice.
    public func clearNotice() { notice = nil }

    /// Shows a short result from an editor-adjacent action such as copy or export.
    public func reportNotice(_ message: String) { notice = message }

    /// Applies an assistant or command edit through the editor's shared undo manager.
    @discardableResult
    public func applyToolFormat(_ request: TextToolFormatRequest) throws -> Int {
        if let file = request.file {
            guard let target = projectFile(matching: file) else {
                throw TextEditorCommandError.fileNotFound(file)
            }
            selectFile(target.id)
        }
        var updated = request.contents ?? text
        let edits = request.edits.sorted {
            if $0.startLine != $1.startLine { return $0.startLine > $1.startLine }
            return $0.endLine > $1.endLine
        }
        var priorStart = Int.max
        for edit in edits {
            guard edit.startLine >= 1, edit.endLine >= edit.startLine,
                let range = Self.lineRange(
                    from: edit.startLine,
                    through: edit.endLine,
                    in: updated
                )
            else {
                throw TextEditorCommandError.invalidLineRange(edit.startLine, edit.endLine)
            }
            guard edit.endLine < priorStart else {
                throw TextEditorCommandError.overlappingLineEdits
            }
            updated = (updated as NSString).replacingCharacters(
                in: range,
                with: edit.replacement
            )
            priorStart = edit.startLine
        }
        if request.trimsTrailingWhitespace {
            updated = TextEditingOperations.trimmingTrailingWhitespace(in: updated)
        }
        if let rawEnding = request.lineEnding {
            guard let ending = LineEnding(rawValue: rawEnding.lowercased()), ending != .mixed else {
                throw TextEditorCommandError.unsupportedLineEnding(rawEnding)
            }
            updated = TextEditingOperations.normalizingLineEndings(in: updated, to: ending)
        }
        guard
            request.contents != nil || !edits.isEmpty || request.trimsTrailingWhitespace
                || request.lineEnding != nil
        else {
            throw TextEditorCommandError.noFormattingRequested
        }
        guard updated != text else { return 0 }
        replaceContentsForCommand(updated, actionName: "Format Text")
        notice = "Updated \(activeFile?.relativePath ?? "the active file")."
        return max(edits.count, 1)
    }

    /// Compiles and waits so an assistant can immediately consume structured diagnostics.
    public func compileForTool() async -> TeXCompilationState {
        requestTeXCompile()
        if needsTeXPackageConsent {
            return .paused("Choose cached-only or network package access in the editor first.")
        }
        let task = texCompileTask
        _ = await task?.value
        return texCompilationState
    }

    /// Returns structured diagnostics with bounded, line-numbered source context.
    public func toolDiagnosticReport(maximumSourceLines: Int = 240) -> String {
        var rows: [String] = []
        if texDiagnostics.isEmpty {
            rows.append("No structured LaTeX diagnostics are available.")
        } else {
            rows.append("LaTeX diagnostics (\(texDiagnostics.count)):")
            rows += texDiagnostics.map { diagnostic in
                let file = diagnostic.file ?? mainFile?.relativePath ?? "unknown"
                let line = diagnostic.line.map(String.init) ?? "?"
                return "\(file):\(line): \(diagnostic.severity.rawValue): \(diagnostic.message)"
            }
        }
        let relevantFiles = Set(
            texDiagnostics.compactMap(\.file)
                + [activeFile?.relativePath, mainFile?.relativePath].compactMap { $0 }
        )
        var remaining = max(maximumSourceLines, 0)
        for file in document.files where relevantFiles.contains(file.relativePath) && remaining > 0
        {
            guard let source = textBuffers[file.id] else { continue }
            let lines = source.components(separatedBy: .newlines)
            let selected = lines.prefix(remaining)
            rows.append("Source \(file.relativePath):")
            rows += selected.enumerated().map { offset, line in "\(offset + 1) │ \(line)" }
            if selected.count < lines.count {
                rows.append("… \(lines.count - selected.count) lines omitted")
            }
            remaining -= selected.count
        }
        return rows.joined(separator: "\n")
    }

    /// Supplies the engine selected by the app's distribution channel.
    public func configureTeXEngine(_ engine: any TeXEngine) {
        texEngine = engine
        if language == .latex { scheduleTeXCompilation() }
    }

    /// Requests a build, showing the package-network decision before first use.
    public func requestTeXCompile() {
        guard language == .latex else { return }
        guard texPackageAccess != nil else {
            needsTeXPackageConsent = true
            return
        }
        beginTeXCompilation()
    }

    /// Persists the package-network choice and resumes the requested build.
    public func resolveTeXPackageConsent(allowNetwork: Bool) {
        let access: TeXPackageAccess = allowNetwork ? .allowNetwork : .cachedOnly
        texPackageAccess = access
        texPreferences.set(access.rawValue, forKey: "clip.tex.packageAccess")
        needsTeXPackageConsent = false
        beginTeXCompilation()
    }

    public func cancelTeXPackageConsent() {
        needsTeXPackageConsent = false
    }

    public func setTeXCompileMode(_ mode: TeXCompileMode) {
        guard texCompileMode != mode else { return }
        texCompileMode = mode
        texPreferences.set(mode.rawValue, forKey: "clip.tex.compileMode")
        if mode == .automatic { scheduleTeXCompilation() }
    }

    public func cancelTeXCompilation() {
        cancelTeXCompilation(resetState: false)
        texCompilationState = texPDFURL == nil ? .idle : .succeeded
    }

    /// Resolves the active source line into the last successful PDF.
    public func forwardTeXSearch(line: Int) -> SyncTeXPDFLocation? {
        guard let texSyncTeXIndex, let activeFile else {
            notice = "No current SyncTeX mapping is available. Build the document first."
            return nil
        }
        guard texSuccessfulSources == textBuffers else {
            notice = "The SyncTeX map is stale. Build the changed source before navigating."
            return nil
        }
        guard
            let location = texSyncTeXIndex.forwardSearch(
                file: activeFile.relativePath,
                line: line
            )
        else {
            notice = "The last build has no PDF mapping for line \(line)."
            return nil
        }
        return location
    }

    /// Resolves a command-click expressed from the PDF page's top-left edge.
    public func inverseTeXSearch(page: Int, x: Double, y: Double) -> SyncTeXSourceLocation? {
        guard let texSyncTeXIndex else {
            notice = "No current SyncTeX mapping is available. Build the document first."
            return nil
        }
        guard texSuccessfulSources == textBuffers else {
            notice = "The SyncTeX map is stale. Build the changed source before navigating."
            return nil
        }
        guard let location = texSyncTeXIndex.inverseSearch(page: page, x: x, y: y) else {
            notice = "No source mapping is available at that PDF position."
            return nil
        }
        if let file = projectFile(matching: location.file) {
            return SyncTeXSourceLocation(
                file: file.relativePath,
                line: location.line,
                column: location.column
            )
        }
        notice = "The mapped source file is no longer part of this project."
        return nil
    }

    public func isActiveFile(path: String) -> Bool {
        projectFile(matching: path)?.id == activeFileID
    }

    /// Updates the layout safety mode reported by the native editor.
    public func setSoftWrapSuppressed(_ suppressed: Bool) {
        guard isSoftWrapSuppressed != suppressed else { return }
        isSoftWrapSuppressed = suppressed
        if suppressed {
            notice =
                "Soft wrap was disabled because this file contains a line over 10,000 characters."
        }
    }

    /// Protects TextKit after accepting a paste larger than the editable threshold.
    public func enterLargePasteReadOnlyMode() {
        isReadOnly = true
        notice = "The large paste was accepted in read-only mode."
    }

    /// Reports that a paste exceeded the hard in-app size limit.
    public func reportPasteRefused() {
        notice = "Pastes over 20 MB cannot be opened in Clip."
    }

    /// Detects a high-confidence language when content is pasted into an empty buffer.
    public func detectPastedLanguage(contents: String) {
        guard let activeFile, !activeFile.languageIsExplicit,
            activeFile.language == .plainText
        else { return }
        let detected = LanguageDetector.detect(path: "", contents: contents)
        guard detected != .plainText else { return }
        do {
            _ = try document.apply(.setLanguage(activeFile.id, detected, explicit: false))
            rebuildTeXProjectAnalysis()
            persistStructureNow()
            notice = "Detected \(detected.rawValue.capitalized)."
        } catch {
            notice = "Clip could not update the detected language."
        }
    }

    /// Explicitly normalizes mixed separators and keeps text plus metadata in one undo step.
    public func normalizeLineEndings(to lineEnding: LineEnding) {
        guard lineEnding != .mixed else { return }
        let normalized = TextEditingOperations.normalizingLineEndings(in: text, to: lineEnding)
        applyLineEndingState(
            text: normalized,
            lineEnding: lineEnding,
            actionName: "Normalize Line Endings"
        )
    }

    /// Whether an external version is waiting for the user's decision.
    public var hasExternalConflict: Bool { pendingExternalContents != nil }

    /// Keeps local edits after an external change and resumes autosave.
    public func keepCurrentVersion() {
        guard pendingExternalContents != nil else { return }
        pendingExternalContents = nil
        scheduleContentAutosave()
        notice = "Keeping your version."
    }

    /// Replaces the current buffer with the version read from disk.
    public func useExternalVersion() {
        guard let pendingExternalContents else { return }
        applyExternalContents(pendingExternalContents)
        notice = "Reloaded the version from disk."
    }

    /// Stages a newly read disk version, or reloads it immediately when clean.
    public func receiveExternalContents(_ contents: LoadedTextFile) {
        guard contents.text != text else {
            updateDetectedFormat(from: contents)
            return
        }
        if isDirty {
            contentTask?.cancel()
            pendingExternalContents = contents
        } else {
            applyExternalContents(contents)
            notice = "Reloaded changes from disk."
        }
    }

    /// Keeps the in-memory buffer alive after its backing file disappears.
    public func receiveExternalDeletion() {
        guard !isDetached else { return }
        contentTask?.cancel()
        pendingExternalContents = nil
        isDetached = true
        hasSavedDetachedCopy = false
        notice = "The file was deleted or moved. Save a copy to keep this buffer."
    }

    /// Writes a detached buffer to a user-selected location without touching the missing asset.
    public func saveDetachedCopy(to url: URL) {
        let fileID = activeFileID
        let value = text
        let encoding = activeFile?.encoding ?? .utf8
        let byteOrderMark = activeFile?.byteOrderMark
        Task { [weak self] in
            let didWrite = await Task.detached(priority: .userInitiated) {
                guard
                    let data = TextFileEncoder.encode(
                        value,
                        using: encoding,
                        byteOrderMark: byteOrderMark
                    )
                else { return false }
                do {
                    try data.write(to: url, options: .atomic)
                    return true
                } catch {
                    return false
                }
            }.value
            guard let self else { return }
            if didWrite, activeFileID == fileID, text == value {
                isDirty = false
                dirtyFileIDs.remove(fileID)
                hasSavedDetachedCopy = true
                notice = "Saved a copy as \(url.lastPathComponent)."
            } else if !didWrite {
                notice = "The detached buffer could not be saved."
            }
        }
    }

    // MARK: - Content persistence

    /// Immediately writes the buffer to disk, cancelling any pending autosave.
    public func saveNow() {
        contentTask?.cancel()
        cleanupTask?.cancel()
        let original = text
        cleanupTask = Task { [weak self] in
            let cleaned = await Task.detached(priority: .userInitiated) {
                TextEditingOperations.trimmingTrailingWhitespace(in: original)
            }.value
            guard !Task.isCancelled, let self else { return }
            if text == original, cleaned != original {
                text = cleaned
                contentTask?.cancel()
            }
            writeContents()
        }
        if language == .latex, texCompileMode == .onSave {
            requestTeXCompile()
        }
    }

    private func scheduleTeXCompilation() {
        guard language == .latex, texCompileMode == .automatic,
            texPackageAccess != nil, texEngine != nil
        else { return }
        texCompileTask?.cancel()
        let generation = UUID()
        texCompileGeneration = generation
        texCompileTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1_500))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, texCompileGeneration == generation else { return }
            guard TeXCompileDiscipline.allowsAutomaticCompileNow else {
                texCompilationState = .paused(
                    "Auto-compile is paused for battery or thermal conditions."
                )
                return
            }
            beginTeXCompilation()
        }
    }

    private func beginTeXCompilation() {
        guard let texEngine, texEngine.isAvailable else {
            texCompilationState = .failed("The bundled TeX engine is unavailable.")
            return
        }
        guard let packageAccess = texPackageAccess else { return }
        rebuildTeXProjectAnalysis()
        guard let analysis = texProjectAnalysis,
            let mainPath = analysis.mainFile,
            let mainFile = document.files.first(where: { $0.relativePath == mainPath })
        else {
            texCompilationState = .failed(
                "Choose a main LaTeX file containing \\documentclass before building."
            )
            return
        }
        texCompileTask?.cancel()
        let generation = UUID()
        texCompileGeneration = generation
        let sourceSnapshot = textBuffers
        let input: TeXInputSnapshot
        do {
            input = try makeTeXInputSnapshot(
                mainFile: mainFile,
                mainPath: mainPath,
                reachablePaths: analysis.reachableFiles,
                sourceSnapshot: sourceSnapshot
            )
        } catch {
            texCompilationState = .failed("Clip could not prepare the LaTeX source workspace.")
            return
        }
        let overrides: [String: Data] = Dictionary(
            uniqueKeysWithValues: document.files.compactMap { file in
                guard analysis.reachableFiles.contains(file.relativePath),
                    let source = sourceSnapshot[file.id]
                else { return nil }
                return (file.relativePath, Data(source.utf8))
            }
        )
        let job = TeXJob(
            mainFile: input.mainFile,
            workingDirectory: input.projectDirectory,
            projectFiles: input.projectFiles,
            sourceOverrides: overrides,
            bibliography: analysis.bibliography,
            timeout: .seconds(120),
            packageAccess: packageAccess
        )
        texCompilationState = .compiling
        texLog = ""
        texDiagnostics = []
        texCompileTask = Task { [weak self] in
            defer {
                if let ephemeralRoot = input.ephemeralRoot {
                    try? FileManager.default.removeItem(at: ephemeralRoot)
                }
            }
            do {
                for try await event in texEngine.compile(job) {
                    guard let self, texCompileGeneration == generation else { return }
                    switch event {
                    case .pass:
                        break
                    case .logLine(let line):
                        texLog += texLog.isEmpty ? line : "\n\(line)"
                    case .diagnostic(let diagnostic):
                        texDiagnostics.append(diagnostic)
                    case .finished(let pdf, let synctex):
                        let index = await Task.detached(priority: .userInitiated) {
                            guard let synctex else { return Optional<SyncTeXIndex>.none }
                            return try? SyncTeXIndex(contentsOf: synctex)
                        }.value
                        guard texCompileGeneration == generation else { return }
                        replaceTeXResults(pdf: pdf, synctex: synctex)
                        texSyncTeXIndex = index
                        texSuccessfulSources = sourceSnapshot
                        texCompilationState = .succeeded
                    }
                }
            } catch TeXEngineError.cancelled {
                return
            } catch is CancellationError {
                return
            } catch {
                guard let self, texCompileGeneration == generation else { return }
                texCompilationState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelTeXCompilation(resetState: Bool) {
        texCompileTask?.cancel()
        texCompileTask = nil
        texCompileGeneration = UUID()
        if resetState { texCompilationState = .idle }
    }

    private func replaceTeXResults(pdf: URL, synctex: URL?) {
        if let previous = texPDFURL, previous != pdf {
            try? FileManager.default.removeItem(at: previous.deletingLastPathComponent())
        }
        texPDFURL = pdf
        texSyncTeXURL = synctex
    }

    private func removeTeXResults() {
        if let texPDFURL {
            try? FileManager.default.removeItem(at: texPDFURL.deletingLastPathComponent())
        }
        texPDFURL = nil
        texSyncTeXURL = nil
        texSyncTeXIndex = nil
        texSuccessfulSources = nil
    }

    private func scheduleContentAutosave() {
        contentTask?.cancel()
        let interval = autosaveInterval
        contentTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.writeContents()
        }
    }

    private func flushContentAutosave() {
        for fileID in dirtyFileIDs {
            guard let value = textBuffers[fileID] else { continue }
            if fileID == activeFileID,
                isDetached || pendingExternalContents != nil
            {
                continue
            }
            writeContents(fileID: fileID, value: value)
        }
    }

    private func writeContents() {
        guard isDirty, !isDetached, pendingExternalContents == nil else { return }
        let fileID = activeFileID
        let value = text
        writeContents(fileID: fileID, value: value)
    }

    private func writeContents(fileID: FileID, value: String) {
        guard dirtyFileIDs.contains(fileID),
            let file = document.files.first(where: { $0.id == fileID })
        else { return }
        let encoding = file.encoding.stringEncoding
        let textEncoding = file.encoding
        let byteOrderMark = file.byteOrderMark
        if activeFileID == fileID { isDirty = false }
        dirtyFileIDs.remove(fileID)
        let hashData = hashData
        let persistContents = persistContents
        Task { [weak self] in
            let payload = await Task.detached(priority: .utility) {
                guard
                    let data =
                        TextFileEncoder.encode(
                            value,
                            using: textEncoding,
                            byteOrderMark: byteOrderMark
                        ) ?? value.data(using: encoding) ?? value.data(using: .utf8)
                else {
                    return Optional<(Data, String)>.none
                }
                return (data, hashData(data))
            }.value
            guard let (data, hash) = payload else {
                self?.dirtyFileIDs.insert(fileID)
                if self?.activeFileID == fileID { self?.isDirty = true }
                self?.notice = "This text could not be encoded for saving."
                return
            }
            do {
                try await persistContents(fileID, data, hash)
            } catch {
                await MainActor.run {
                    self?.dirtyFileIDs.insert(fileID)
                    if self?.activeFileID == fileID { self?.isDirty = true }
                    self?.notice = "The file could not be saved."
                }
            }
        }
    }

    private func persistStructureNow() {
        structureTask?.cancel()
        let document = document
        let persistStructure = persistStructure
        structureTask = Task { [weak self] in
            do {
                try await persistStructure(document)
            } catch {
                self?.notice = "The document could not be saved locally."
            }
        }
    }

    private func applyLineEndingState(
        text updatedText: String,
        lineEnding: LineEnding,
        actionName: String
    ) {
        guard let activeFile else { return }
        let previousText = text
        let previousLineEnding = activeFile.lineEnding
        guard updatedText != previousText || lineEnding != previousLineEnding else { return }
        do {
            _ = try document.apply(.setLineEnding(activeFile.id, lineEnding))
            text = updatedText
            undoManager.registerUndo(withTarget: self) { target in
                target.applyLineEndingState(
                    text: previousText,
                    lineEnding: previousLineEnding,
                    actionName: actionName
                )
            }
            undoManager.setActionName(actionName)
            persistStructureNow()
        } catch {
            notice = "The line endings could not be normalized."
        }
    }

    private func scheduleExternalReload() {
        guard let sourceURL else { return }
        externalReloadTask?.cancel()
        externalReloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                let loaded = try await Task.detached(priority: .utility) {
                    try TextFileLoader.load(from: sourceURL)
                }.value
                guard !Task.isCancelled else { return }
                self?.receiveExternalContents(loaded)
            } catch is CancellationError {
                return
            } catch {
                guard !FileManager.default.fileExists(atPath: sourceURL.path) else { return }
                self?.receiveExternalDeletion()
            }
        }
    }

    private func applyExternalContents(_ contents: LoadedTextFile) {
        contentTask?.cancel()
        cleanupTask?.cancel()
        pendingExternalContents = nil
        isApplyingExternalText = true
        text = contents.text
        textBuffers[activeFileID] = contents.text
        isApplyingExternalText = false
        isDirty = false
        dirtyFileIDs.remove(activeFileID)
        hasSavedDetachedCopy = false
        undoManager.removeAllActions()
        updateDetectedFormat(from: contents)
    }

    private func updateDetectedFormat(from contents: LoadedTextFile) {
        guard let activeFile else { return }
        do {
            var didChange = false
            if activeFile.encoding != contents.encoding
                || activeFile.byteOrderMark != contents.byteOrderMark
            {
                _ = try document.apply(
                    .setEncoding(
                        activeFile.id,
                        contents.encoding,
                        byteOrderMark: contents.byteOrderMark
                    )
                )
                didChange = true
            }
            if self.activeFile?.lineEnding != contents.lineEnding {
                _ = try document.apply(.setLineEnding(activeFile.id, contents.lineEnding))
                didChange = true
            }
            if self.activeFile?.languageIsExplicit == false {
                let detected = LanguageDetector.detect(
                    path: activeFile.relativePath,
                    contents: contents.text
                )
                if self.activeFile?.language != detected {
                    _ = try document.apply(.setLanguage(activeFile.id, detected, explicit: false))
                    didChange = true
                }
            }
            if didChange { persistStructureNow() }
        } catch {
            notice = "The file format metadata could not be refreshed."
        }
    }

    private func registerUndo(_ patch: TextPatch, actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            do {
                let redo = try target.document.apply(patch)
                target.registerUndo(redo, actionName: actionName)
                target.undoManager.setActionName(actionName)
                target.rebuildTeXProjectAnalysis()
                target.persistStructureNow()
            } catch {
                target.notice = "That change could not be undone."
            }
        }
    }

    private func replaceContentsForCommand(_ value: String, actionName: String) {
        let previous = text
        undoManager.registerUndo(withTarget: self) { target in
            target.replaceContentsForCommand(previous, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        text = value
    }

    private static func lineRange(
        from startLine: Int,
        through endLine: Int,
        in text: String
    ) -> NSRange? {
        let source = text as NSString
        var currentLine = 1
        var location = 0
        while currentLine < startLine, location < source.length {
            var end = 0
            source.getLineStart(
                nil, end: &end, contentsEnd: nil, for: NSRange(location: location, length: 0))
            location = end
            currentLine += 1
        }
        guard currentLine == startLine, location <= source.length else { return nil }
        let start = location
        while currentLine <= endLine, location < source.length {
            var end = 0
            source.getLineStart(
                nil, end: &end, contentsEnd: nil, for: NSRange(location: location, length: 0))
            location = end
            currentLine += 1
        }
        guard currentLine > endLine else {
            if start == source.length, startLine == endLine {
                return NSRange(location: start, length: 0)
            }
            return nil
        }
        return NSRange(location: start, length: location - start)
    }

    private func rebuildTeXProjectAnalysis() {
        let sources = Dictionary(
            uniqueKeysWithValues: document.files.compactMap { file in
                textBuffers[file.id].map { (file.relativePath, $0) }
            }
        )
        guard
            sources.values.contains(where: { $0.contains("\\documentclass") })
                || document.files.contains(where: { $0.language == .latex })
        else {
            texProjectAnalysis = nil
            return
        }
        let selectedMain = document.mainFileID.flatMap { id in
            document.files.first(where: { $0.id == id })?.relativePath
        }
        texProjectAnalysis = TeXProjectAnalyzer.analyze(
            sources: sources,
            availableFiles: Set(projectFileURLs.keys).union(sources.keys),
            selectedMainFile: selectedMain
        )
    }

    private struct TeXInputSnapshot {
        var mainFile: URL
        var projectDirectory: URL
        var projectFiles: [URL]
        var ephemeralRoot: URL?
    }

    /// Materializes scratch buffers only for the lifetime of a compile. This
    /// gives an unsaved `Untitled.tex` the same confined compiler path as a
    /// library file without turning the scratch buffer into a permanent asset.
    private func makeTeXInputSnapshot(
        mainFile: TextFile,
        mainPath: String,
        reachablePaths: Set<String>,
        sourceSnapshot: [FileID: String]
    ) throws -> TeXInputSnapshot {
        if let mainURL = sourceURLs[mainFile.id] {
            return TeXInputSnapshot(
                mainFile: mainURL,
                projectDirectory: Self.projectRoot(for: mainPath, sourceURL: mainURL),
                projectFiles: reachablePaths.compactMap { projectFileURLs[$0] },
                ephemeralRoot: nil
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-text-source-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var urls: [URL] = []
            for file in document.files where reachablePaths.contains(file.relativePath) {
                guard let value = sourceSnapshot[file.id],
                    let destination = Self.safeTeXDestination(file.relativePath, below: root)
                else {
                    throw TextEditorCommandError.fileNotFound(file.relativePath)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(value.utf8).write(to: destination, options: .atomic)
                urls.append(destination)
            }
            guard let mainURL = Self.safeTeXDestination(mainPath, below: root),
                FileManager.default.isReadableFile(atPath: mainURL.path)
            else {
                throw TextEditorCommandError.fileNotFound(mainPath)
            }
            return TeXInputSnapshot(
                mainFile: mainURL,
                projectDirectory: root,
                projectFiles: urls,
                ephemeralRoot: root
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static func safeTeXDestination(_ path: String, below root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), URL(string: path)?.scheme == nil else {
            return nil
        }
        let destination = root.appendingPathComponent(path).standardizedFileURL
        let prefix = root.standardizedFileURL.path + "/"
        return destination.path.hasPrefix(prefix) ? destination : nil
    }

    private static func isDefaultScratchName(_ path: String) -> Bool {
        ["untitled", "untitled.txt", "untitled.md", "untitled.tex"].contains(path.lowercased())
    }

    private static func preferredScratchExtension(for language: LanguageID) -> String? {
        switch language {
        case .markdown: "md"
        case .latex: "tex"
        case .plainText: "txt"
        default: nil
        }
    }

    private func startFileMonitor() {
        guard fileMonitor == nil, let sourceURL else { return }
        fileMonitor = TextFileMonitor(url: sourceURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleExternalReload()
            }
        }
    }

    private static func projectRoot(for relativePath: String, sourceURL: URL) -> URL {
        var root = sourceURL
        let depth = relativePath.split(separator: "/").count
        for _ in 0..<depth { root.deleteLastPathComponent() }
        return root
    }

    private static func projectPathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        return rhs.hasSuffix("/\(lhs)") || lhs.hasSuffix("/\(rhs)")
    }

    private func projectFile(matching path: String) -> TextFile? {
        if let exact = document.files.first(where: { $0.relativePath == path }) {
            return exact
        }
        let matches = document.files.filter {
            Self.projectPathsMatch($0.relativePath, path)
        }
        let maximumDepth = matches.map {
            $0.relativePath.split(separator: "/").count
        }.max()
        let mostSpecific = matches.filter {
            $0.relativePath.split(separator: "/").count == maximumDepth
        }
        return mostSpecific.count == 1 ? mostSpecific[0] : nil
    }

    private static func isTeXSource(_ path: String) -> Bool {
        ["tex", "latex"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

private final class TextFileMonitor: @unchecked Sendable {
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject
    private var isCancelled = false

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue(label: "app.clip.text-file-monitor", qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        source.cancel()
    }

    deinit { cancel() }
}
