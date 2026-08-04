import AppKit
import CoreModel
import Foundation
import Testing
import TextEngine

@testable import ReelAppCore

@MainActor
@Suite("Text editor")
struct TextEditorViewModelTests {
    @Test("Native typing can register and undo edits")
    func nativeTypingUsesEventGroupedUndo() throws {
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "Untitled.txt")
        let document = try TextDocument(files: [file])
        let editor = TextEditorViewModel(
            document: document,
            text: "",
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in }
        )
        let textView = UndoBackedTextView(usingTextLayoutManager: true)
        textView.providedUndoManager = editor.undoManager
        textView.isEditable = true

        #expect(editor.undoManager.groupsByEvent)
        textView.insertText(
            "Clip typing works",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(textView.string == "Clip typing works")
        #expect(editor.undoManager.canUndo)
        editor.undo()
        #expect(textView.string.isEmpty)
    }

    @Test("Mixed line ending normalization is one undoable edit")
    func normalizesMixedLineEndings() throws {
        let file = TextFile(
            id: FileID(rawValue: "main"),
            relativePath: "Mixed.txt",
            lineEnding: .mixed
        )
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file]),
            text: "one\r\ntwo\nthree\r",
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in }
        )

        editor.normalizeLineEndings(to: .lf)

        #expect(editor.text == "one\ntwo\nthree\n")
        #expect(editor.activeFile?.lineEnding == .lf)
        editor.undo()
        #expect(editor.text == "one\r\ntwo\nthree\r")
        #expect(editor.activeFile?.lineEnding == .mixed)
    }

    @Test("Clean external edits reload while dirty edits require a choice")
    func handlesExternalChangesWithoutDiscardingLocalEdits() throws {
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "Notes.txt")
        let cleanEditor = try makeEditor(file: file, text: "original")
        let diskVersion = LoadedTextFile(
            text: "changed on disk",
            encoding: .utf8,
            lineEnding: .lf
        )

        cleanEditor.receiveExternalContents(diskVersion)
        #expect(cleanEditor.text == "changed on disk")
        #expect(!cleanEditor.isDirty)
        #expect(!cleanEditor.hasExternalConflict)

        let dirtyEditor = try makeEditor(file: file, text: "original")
        dirtyEditor.text = "my unsaved edit"
        dirtyEditor.receiveExternalContents(diskVersion)
        #expect(dirtyEditor.text == "my unsaved edit")
        #expect(dirtyEditor.hasExternalConflict)

        dirtyEditor.useExternalVersion()
        #expect(dirtyEditor.text == "changed on disk")
        #expect(!dirtyEditor.isDirty)
        #expect(!dirtyEditor.hasExternalConflict)
    }

    @Test("Deletion detaches the buffer instead of discarding it")
    func keepsDeletedFileBufferInMemory() throws {
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "Notes.txt")
        let editor = try makeEditor(file: file, text: "keep me")

        editor.receiveExternalDeletion()

        #expect(editor.text == "keep me")
        #expect(editor.isDetached)
        #expect(!editor.hasSavedDetachedCopy)
    }

    @Test("Directory monitoring reloads an atomic external save")
    func monitorsExternalAtomicWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-text-monitor-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Notes.txt")
        try Data("original".utf8).write(to: url)
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "Notes.txt")
        let editor = try makeEditor(file: file, text: "original", sourceURL: url)
        editor.start()
        defer { editor.stop() }

        try Data("changed atomically".utf8).write(to: url, options: .atomic)
        for _ in 0..<30 where editor.text != "changed atomically" {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(editor.text == "changed atomically")
        #expect(!editor.isDirty)
    }

    @Test("A five megabyte buffer survives fifty native undo steps")
    func fiveMegabyteUndoAcceptance() throws {
        let original = String(repeating: "a", count: 5 * 1024 * 1024)
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "Large.txt")
        let editor = try makeEditor(file: file, text: original)
        let textView = UndoBackedTextView(usingTextLayoutManager: true)
        textView.providedUndoManager = editor.undoManager
        textView.isEditable = true
        textView.string = original
        textView.setSelectedRange(NSRange(location: original.utf16.count, length: 0))

        for _ in 0..<50 {
            textView.insertText(
                "x",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            textView.breakUndoCoalescing()
        }
        #expect(textView.string.utf16.count == original.utf16.count + 50)

        for _ in 0..<50 { editor.undo() }
        #expect(textView.string == original)
    }

    @Test("LaTeX package access is an explicit one-time choice")
    func latexPackageConsent() throws {
        let fixture = try TeXEditorFixture()
        defer { fixture.remove() }
        let editor = try fixture.editor(engine: StubTeXEngine.result(.success))

        editor.requestTeXCompile()
        #expect(editor.needsTeXPackageConsent)

        editor.resolveTeXPackageConsent(allowNetwork: false)
        #expect(!editor.needsTeXPackageConsent)
        #expect(editor.texPackageAccess == .cachedOnly)
        #expect(
            fixture.preferences.string(forKey: "clip.tex.packageAccess")
                == TeXPackageAccess.cachedOnly.rawValue
        )
    }

    @Test("A failed rebuild keeps the last successful LaTeX PDF visible")
    func latexRetainsLastSuccessfulPDF() async throws {
        let fixture = try TeXEditorFixture(packageAccess: .cachedOnly)
        defer { fixture.remove() }
        let editor = try fixture.editor(engine: StubTeXEngine.result(.success))

        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .succeeded }
        let successfulPDF = try #require(editor.texPDFURL)
        #expect(FileManager.default.fileExists(atPath: successfulPDF.path))

        editor.configureTeXEngine(StubTeXEngine.result(.failure))
        editor.requestTeXCompile()
        await waitUntil {
            if case .failed = editor.texCompilationState { return true }
            return false
        }

        #expect(editor.texPDFURL == successfulPDF)
        #expect(FileManager.default.fileExists(atPath: successfulPDF.path))
    }

    @Test("Cancelling a LaTeX build returns the editor to a stable state")
    func cancellingLatexBuildResetsState() async throws {
        let fixture = try TeXEditorFixture(packageAccess: .cachedOnly)
        defer { fixture.remove() }
        let editor = try fixture.editor(engine: StubTeXEngine.result(.neverFinishes))

        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .compiling }
        editor.cancelTeXCompilation()

        #expect(editor.texCompilationState == .idle)
    }

    @Test("Editing an included file builds the main file with bibliography dependencies")
    func multiFileLatexBuildUsesMainDependencyGraph() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-multifile-editor-\(UUID().uuidString)",
            isDirectory: true
        )
        let chapters = root.appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mainID = FileID(rawValue: "main")
        let chapterID = FileID(rawValue: "chapter")
        let bibID = FileID(rawValue: "bib")
        let mainURL = root.appendingPathComponent("main.tex")
        let chapterURL = chapters.appendingPathComponent("intro.tex")
        let bibURL = root.appendingPathComponent("refs.bib")
        let mainSource = "\\documentclass{article}\\input{chapters/intro}\\bibliography{refs}"
        let chapterSource = "Included chapter"
        let bibliography = "@book{clip,title={Clip}}"
        let contents = [mainID: mainSource, chapterID: chapterSource, bibID: bibliography]
        for (url, value) in [
            (mainURL, mainSource),
            (chapterURL, chapterSource),
            (bibURL, bibliography),
        ] {
            try Data(value.utf8).write(to: url)
        }
        let document = try TextDocument(
            files: [
                TextFile(id: mainID, relativePath: "main.tex", language: .latex),
                TextFile(
                    id: chapterID,
                    relativePath: "chapters/intro.tex",
                    language: .latex
                ),
                TextFile(id: bibID, relativePath: "refs.bib", language: .latex),
            ],
            mainFileID: mainID
        )
        let preferences = try makeTeXPreferences(packageAccess: .cachedOnly)
        let recorder = TeXJobRecorder()
        let editor = TextEditorViewModel(
            document: document,
            contents: contents,
            activeFileID: chapterID,
            sourceURLs: [mainID: mainURL, chapterID: chapterURL, bibID: bibURL],
            projectFileURLs: [
                "main.tex": mainURL,
                "chapters/intro.tex": chapterURL,
                "refs.bib": bibURL,
            ],
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _, _ in },
            texPreferences: preferences
        )
        editor.configureTeXEngine(RecordingTeXEngine(recorder: recorder))

        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .succeeded }
        let job = try #require(recorder.job)

        #expect(job.mainFile == mainURL)
        #expect(Set(job.projectFiles) == Set([mainURL, chapterURL, bibURL]))
        #expect(Set(job.sourceOverrides.keys) == ["main.tex", "chapters/intro.tex", "refs.bib"])
        #expect(job.bibliography == .bibtex)
    }

    @Test("Switching project files saves every edited buffer")
    func switchingFilesPreservesAllPendingEdits() async throws {
        let firstID = FileID(rawValue: "first")
        let secondID = FileID(rawValue: "second")
        let document = try TextDocument(
            files: [
                TextFile(id: firstID, relativePath: "main.tex", language: .latex),
                TextFile(id: secondID, relativePath: "chapter.tex", language: .latex),
            ],
            mainFileID: firstID
        )
        let writes = TextWriteRecorder()
        let editor = TextEditorViewModel(
            document: document,
            contents: [firstID: "first", secondID: "second"],
            activeFileID: firstID,
            sourceURLs: [:],
            projectFileURLs: [:],
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { fileID, data, _ in
                await writes.record(fileID, data: data)
            }
        )

        editor.text = "edited first"
        editor.selectFile(secondID)
        editor.text = "edited second"
        editor.stop()

        for _ in 0..<50 {
            if await writes.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await writes.text(for: firstID) == "edited first")
        #expect(await writes.text(for: secondID) == "edited second")
    }

    private func makeEditor(
        file: TextFile,
        text: String,
        sourceURL: URL? = nil
    ) throws -> TextEditorViewModel {
        TextEditorViewModel(
            document: try TextDocument(files: [file]),
            text: text,
            sourceURL: sourceURL,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in }
        )
    }
}

private func makeTeXPreferences(packageAccess: TeXPackageAccess) throws -> UserDefaults {
    let suite = "clip-tex-preferences-\(UUID().uuidString)"
    guard let preferences = UserDefaults(suiteName: suite) else {
        throw CocoaError(.fileReadUnknown)
    }
    preferences.removePersistentDomain(forName: suite)
    preferences.set(TeXCompileMode.manual.rawValue, forKey: "clip.tex.compileMode")
    preferences.set(packageAccess.rawValue, forKey: "clip.tex.packageAccess")
    return preferences
}

private final class TeXJobRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedJob: TeXJob?

    var job: TeXJob? {
        lock.lock()
        defer { lock.unlock() }
        return storedJob
    }

    func record(_ job: TeXJob) {
        lock.lock()
        storedJob = job
        lock.unlock()
    }
}

private actor TextWriteRecorder {
    private var writes: [FileID: String] = [:]

    var count: Int { writes.count }

    func record(_ id: FileID, data: Data) {
        writes[id] = String(data: data, encoding: .utf8)
    }

    func text(for id: FileID) -> String? { writes[id] }
}

private struct RecordingTeXEngine: TeXEngine {
    let id: EngineID = "recording-test"
    let displayName = "Recording Test TeX"
    let isAvailable = true
    let recorder: TeXJobRecorder

    func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        recorder.record(job)
        return AsyncThrowingStream { continuation in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "clip-recording-tex-result-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let pdf = directory.appendingPathComponent("main.pdf")
                try Data("%PDF-test".utf8).write(to: pdf)
                continuation.yield(.finished(pdf: pdf, synctex: nil))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

@MainActor
private func waitUntil(
    attempts: Int = 50,
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<attempts {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private struct TeXEditorFixture {
    let directory: URL
    let source: URL
    let preferences: UserDefaults

    init(packageAccess: TeXPackageAccess? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-tex-editor-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("main.tex")
        try Data("\\documentclass{article}\\begin{document}Hi\\end{document}".utf8)
            .write(to: source)
        let suite = "clip-tex-editor-tests-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else {
            throw CocoaError(.fileReadUnknown)
        }
        self.preferences = preferences
        preferences.removePersistentDomain(forName: suite)
        preferences.set(TeXCompileMode.manual.rawValue, forKey: "clip.tex.compileMode")
        if let packageAccess {
            preferences.set(packageAccess.rawValue, forKey: "clip.tex.packageAccess")
        }
    }

    @MainActor
    func editor(engine: some TeXEngine) throws -> TextEditorViewModel {
        let file = TextFile(
            id: FileID(rawValue: "main"),
            relativePath: "main.tex",
            language: .latex,
            languageIsExplicit: true
        )
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file]),
            text: try String(contentsOf: source, encoding: .utf8),
            sourceURL: source,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in },
            texPreferences: preferences
        )
        editor.configureTeXEngine(engine)
        return editor
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct StubTeXEngine: TeXEngine {
    enum Result: Sendable {
        case success
        case failure
        case neverFinishes
    }

    let id: EngineID = "test"
    let displayName = "Test TeX"
    let isAvailable = true
    let result: Result

    static func result(_ result: Result) -> Self { Self(result: result) }

    func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch result {
                case .success:
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "clip-tex-test-result-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    let pdf = directory.appendingPathComponent("main.pdf")
                    try Data("%PDF-test".utf8).write(to: pdf)
                    continuation.yield(.finished(pdf: pdf, synctex: nil))
                    continuation.finish()
                case .failure:
                    continuation.finish(
                        throwing: TeXEngineError.compilationFailed(
                            status: 1,
                            message: "Expected test failure"
                        )
                    )
                case .neverFinishes:
                    do {
                        try await Task.sleep(for: .seconds(60))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: TeXEngineError.cancelled)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private final class UndoBackedTextView: NSTextView {
    weak var providedUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        providedUndoManager ?? super.undoManager
    }
}
