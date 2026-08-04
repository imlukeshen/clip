import AppKit
import CoreModel
import Foundation
import LibraryStore
import Observation
import TextEngine

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
            isDirty = true
            scheduleContentAutosave()
        }
    }
    /// The file currently shown in the editor.
    public private(set) var activeFileID: FileID
    /// A transient status line message.
    public private(set) var notice: String?
    /// Whether the buffer has unsaved changes since the last content save.
    public private(set) var isDirty = false

    /// The source file on disk, or `nil` for an unsaved scratch buffer.
    public let sourceURL: URL?
    /// The undo manager shared by the text view and document-level patches.
    public let undoManager = UndoManager()

    /// Recomputes the content hash for an in-place save, matching ingest's scheme.
    private let hashData: @Sendable (Data) -> String
    /// Persists the structural document overlay (`.reel/text/*.reeltext`).
    private let persistStructure: @Sendable (TextDocument) async throws -> Void
    /// Persists the buffer contents to their on-disk home (library file or scratch).
    private let persistContents: @Sendable (Data, String) async throws -> Void

    private var structureTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?

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
    public init(
        document: TextDocument,
        text: String,
        activeFileID: FileID? = nil,
        sourceURL: URL?,
        hashingWith hashData: @escaping @Sendable (Data) -> String,
        persistingStructure: @escaping @Sendable (TextDocument) async throws -> Void,
        persistingContents: @escaping @Sendable (Data, String) async throws -> Void
    ) {
        self.document = document
        self.text = text
        self.activeFileID = activeFileID ?? document.files[0].id
        self.sourceURL = sourceURL
        self.hashData = hashData
        self.persistStructure = persistingStructure
        self.persistContents = persistingContents
        undoManager.groupsByEvent = false
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

    public func start() {}

    public func stop() {
        structureTask?.cancel()
        contentTask?.cancel()
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
            persistStructureNow()
        } catch {
            notice = "That change could not be applied."
        }
    }

    /// Sets the active file's highlighting language as an explicit user choice.
    public func setLanguage(_ language: LanguageID) {
        guard let activeFile, activeFile.language != language else { return }
        perform(
            .setLanguage(activeFileID, language, explicit: true),
            actionName: "Set Language"
        )
    }

    /// Replaces the shared editor settings.
    public func updateSettings(_ settings: EditorSettings) {
        guard document.settings != settings else { return }
        perform(.setSettings(settings), actionName: "Editor Settings")
    }

    public func undo() { undoManager.undo() }
    public func redo() { undoManager.redo() }

    public func clearNotice() { notice = nil }

    // MARK: - Content persistence

    /// Immediately writes the buffer to disk, cancelling any pending autosave.
    public func saveNow() {
        contentTask?.cancel()
        writeContents()
    }

    private func scheduleContentAutosave() {
        contentTask?.cancel()
        let interval = autosaveInterval
        contentTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.writeContents()
        }
    }

    private func flushContentAutosave() {
        guard isDirty else { return }
        writeContents()
    }

    private func writeContents() {
        guard isDirty else { return }
        let encoding = activeFile?.encoding.stringEncoding ?? .utf8
        guard let data = text.data(using: encoding) ?? text.data(using: .utf8) else {
            notice = "This text could not be encoded for saving."
            return
        }
        isDirty = false
        let hash = hashData(data)
        let persistContents = persistContents
        Task { [weak self] in
            do {
                try await persistContents(data, hash)
            } catch {
                await MainActor.run {
                    self?.isDirty = true
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

    private func registerUndo(_ patch: TextPatch, actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            do {
                let redo = try target.document.apply(patch)
                target.registerUndo(redo, actionName: actionName)
                target.undoManager.setActionName(actionName)
                target.persistStructureNow()
            } catch {
                target.notice = "That change could not be undone."
            }
        }
    }
}
