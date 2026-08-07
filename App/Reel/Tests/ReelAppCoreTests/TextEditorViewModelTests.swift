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
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let textView = UndoBackedTextView(frame: .zero, textContainer: container)
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

    @Test("Pasting into an empty plain buffer detects a high-confidence language")
    func emptyPasteDetectsLanguage() throws {
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "Untitled.txt")
        let editor = try makeEditor(file: file, text: "")

        editor.text = "{\"clip\": true}"
        editor.detectPastedLanguage(contents: editor.text)

        #expect(editor.language == .json)
        #expect(editor.activeFile?.languageIsExplicit == false)
    }

    @Test("Typing auto-detects language without a manual selection")
    func typingDetectsLanguage() async throws {
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "Untitled.txt")
        let editor = try makeEditor(file: file, text: "")

        editor.text = "import SwiftUI\n\n@main struct ClipApp: App {}"
        for _ in 0..<30 where editor.language != .swift {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(editor.language == .swift)
        #expect(editor.activeFile?.languageIsExplicit == false)
    }

    @Test("Auto-detected LaTeX promotes a scratch file and builds without a manual selection")
    func autoDetectedLatexPromotesAndBuildsScratch() async throws {
        let file = TextFile(id: FileID(rawValue: "auto-latex"), relativePath: "Untitled.txt")
        let recorder = TeXJobRecorder()
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file]),
            text: "",
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in },
            texPreferences: try makeTeXPreferences(packageAccess: .cachedOnly)
        )
        editor.configureTeXEngine(RecordingTeXEngine(recorder: recorder))

        editor.text = "\\documentclass{article}\\begin{document}Clip\\end{document}"
        for _ in 0..<30 where editor.activeFile?.relativePath != "Untitled.tex" {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(editor.language == .latex)
        #expect(editor.activeFile?.languageIsExplicit == false)
        #expect(editor.activeFile?.relativePath == "Untitled.tex")

        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .succeeded }

        let job = try #require(recorder.job)
        #expect(job.mainFile.lastPathComponent == "Untitled.tex")
        #expect(recorder.mainSource?.contains("\\documentclass{article}") == true)
        editor.stop()
    }

    @Test("Auto-detected LaTeX chooses a unique scratch filename")
    func autoDetectedLatexAvoidsFilenameCollision() async throws {
        let scratchID = FileID(rawValue: "auto-latex-collision")
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [
                TextFile(id: scratchID, relativePath: "Untitled.txt"),
                TextFile(id: FileID(rawValue: "existing-tex"), relativePath: "Untitled.tex"),
            ]),
            text: "",
            activeFileID: scratchID,
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in }
        )

        editor.text = "\\documentclass{article}\\begin{document}Clip\\end{document}"
        for _ in 0..<30 where editor.activeFile?.relativePath != "Untitled 2.tex" {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(editor.language == .latex)
        #expect(editor.activeFile?.relativePath == "Untitled 2.tex")

        editor.text = ""
        try await Task.sleep(for: .milliseconds(500))
        #expect(editor.language == .plainText)
        editor.stop()
    }

    @Test("An explicit LaTeX choice also avoids an existing scratch filename")
    func explicitLatexAvoidsFilenameCollision() throws {
        let scratchID = FileID(rawValue: "explicit-latex-collision")
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [
                TextFile(id: scratchID, relativePath: "Untitled.txt"),
                TextFile(
                    id: FileID(rawValue: "existing-explicit-tex"),
                    relativePath: "Untitled.tex"
                ),
            ]),
            text: "",
            activeFileID: scratchID,
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in }
        )

        editor.setLanguage(.latex)

        #expect(editor.language == .latex)
        #expect(editor.activeFile?.languageIsExplicit == true)
        #expect(editor.activeFile?.relativePath == "Untitled 2.tex")
        editor.stop()
    }

    @Test("A nested user file is never treated as a generated scratch name")
    func nestedUntitledFileKeepsItsPath() throws {
        let file = TextFile(
            id: FileID(rawValue: "nested-untitled"),
            relativePath: "chapters/Untitled.txt"
        )
        let editor = try makeEditor(file: file, text: "")

        editor.setLanguage(.latex)

        #expect(editor.language == .latex)
        #expect(editor.activeFile?.relativePath == "chapters/Untitled.txt")
        editor.stop()
    }

    @Test("An explicit language choice is not replaced while typing")
    func explicitLanguageWinsOverDetection() async throws {
        let file = TextFile(id: FileID(rawValue: "main"), relativePath: "Untitled.txt")
        let editor = try makeEditor(file: file, text: "")
        editor.setLanguage(.markdown)

        editor.text = "import SwiftUI\n\n@main struct ClipApp: App {}"
        try await Task.sleep(for: .milliseconds(500))

        #expect(editor.language == .markdown)
        #expect(editor.activeFile?.languageIsExplicit == true)
    }

    @Test("A populated Markdown document keeps one stable editor mode")
    func populatedMarkdownDoesNotReclassifyWhileTyping() async throws {
        let file = TextFile(
            id: FileID(rawValue: "markdown-detected"),
            relativePath: "Notes.md",
            language: .markdown,
            languageIsExplicit: false
        )
        let editor = try makeEditor(file: file, text: "# Notes")

        editor.text = "```swift\nimport SwiftUI\nstruct Card: View {}\n```"
        try await Task.sleep(for: .milliseconds(500))

        #expect(editor.language == .markdown)
        #expect(editor.activeFile?.languageIsExplicit == false)
    }

    @Test("Saving Markdown preserves empty block markers and rich formatting source")
    func markdownFormattingPersistsExactly() async throws {
        let fileID = FileID(rawValue: "markdown")
        let file = TextFile(
            id: fileID,
            relativePath: "Notes.md",
            language: .markdown,
            languageIsExplicit: true
        )
        let writes = TextWriteRecorder()
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file]),
            contents: [fileID: ""],
            activeFileID: fileID,
            sourceURLs: [:],
            projectFileURLs: [:],
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { id, data, _ in
                await writes.record(id, data: data)
            }
        )
        let source = "# Heading\n\nA **bold** note.\n\n# "
        editor.text = source
        editor.saveNow()

        for _ in 0..<50 {
            if await writes.text(for: fileID) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await writes.text(for: fileID) == source)
        #expect(
            MarkdownFormattingOperations.blockStyle(
                in: source,
                selectedRange: NSRange(location: (source as NSString).length, length: 0)
            ) == .heading(1)
        )
        editor.stop()
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

    @Test("A scratch buffer switches preview modes and compiles without becoming an asset")
    func scratchPreviewModesAndLatexBuild() async throws {
        let file = TextFile(id: FileID(rawValue: "scratch"), relativePath: "Untitled.txt")
        let preferences = try makeTeXPreferences(packageAccess: .cachedOnly)
        let recorder = TeXJobRecorder()
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file]),
            text: "# Clip",
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in },
            texPreferences: preferences
        )

        editor.setLanguage(.markdown)
        #expect(editor.activeFile?.relativePath == "Untitled.md")
        #expect(editor.language == .markdown)

        editor.text = "\\documentclass{article}\\begin{document}Clip\\end{document}"
        editor.setLanguage(.latex)
        editor.configureTeXEngine(RecordingTeXEngine(recorder: recorder))
        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .succeeded }

        let job = try #require(recorder.job)
        #expect(editor.activeFile?.relativePath == "Untitled.tex")
        #expect(job.mainFile.lastPathComponent == "Untitled.tex")
        #expect(recorder.mainSource?.contains("\\documentclass{article}") == true)
        #expect(editor.texPDFURL != nil)
        editor.stop()
    }

    @Test("A scratch filename is safe, keeps its extension, persists, and is undoable")
    func renamesScratchFile() async throws {
        let file = TextFile(
            id: FileID(rawValue: "scratch-name"),
            relativePath: "Untitled.md",
            language: .markdown,
            languageIsExplicit: true
        )
        let structures = TextDocumentRecorder()
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file]),
            text: "# Notes",
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { document in await structures.record(document) },
            persistingContents: { _, _ in }
        )

        #expect(editor.renameActiveScratchFile(to: "  Meeting Notes  "))
        #expect(editor.activeFile?.relativePath == "Meeting Notes.md")
        for _ in 0..<30 where await structures.path != "Meeting Notes.md" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await structures.path == "Meeting Notes.md")

        #expect(!editor.renameActiveScratchFile(to: "folder/notes"))
        #expect(!editor.renameActiveScratchFile(to: ".hidden"))
        #expect(editor.activeFile?.relativePath == "Meeting Notes.md")

        editor.undo()
        #expect(editor.activeFile?.relativePath == "Untitled.md")
        editor.redo()
        #expect(editor.activeFile?.relativePath == "Meeting Notes.md")
    }

    @Test("A library rename relocates the active source and LaTeX project maps")
    func relocatesRenamedLibrarySource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-text-relocation-\(UUID().uuidString)",
            isDirectory: true
        )
        let chapters = root.appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = chapters.appendingPathComponent("main.tex")
        let newURL = chapters.appendingPathComponent("launch:final.tex")
        let source = "\\documentclass{article}\\begin{document}Clip\\end{document}"
        try Data(source.utf8).write(to: oldURL)

        let fileID = FileID(rawValue: "relocated-main")
        let assetID = AssetID(rawValue: "relocated-asset")
        let file = TextFile(
            id: fileID,
            assetID: assetID,
            relativePath: "chapters/main.tex",
            language: .latex,
            languageIsExplicit: true
        )
        let preferences = try makeTeXPreferences(packageAccess: .cachedOnly)
        let jobs = TeXJobRecorder()
        let structures = TextDocumentRecorder()
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file], mainFileID: fileID),
            contents: [fileID: source],
            activeFileID: fileID,
            sourceURLs: [fileID: oldURL],
            projectFileURLs: ["chapters/main.tex": oldURL],
            hashingWith: { _ in "hash" },
            persistingStructure: { document in await structures.record(document) },
            persistingContents: { _, _, _ in },
            texPreferences: preferences
        )
        editor.configureTeXEngine(RecordingTeXEngine(recorder: jobs))
        editor.start()
        defer { editor.stop() }

        try FileManager.default.moveItem(at: oldURL, to: newURL)
        #expect(
            editor.relocateSource(
                for: assetID,
                to: newURL,
                displayName: "launch:final.tex"
            )
        )
        #expect(editor.sourceURL == newURL.standardizedFileURL)
        #expect(editor.activeFile?.relativePath == "chapters/launch:final.tex")
        #expect(!editor.isDetached)

        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .succeeded }
        let job = try #require(jobs.job)
        #expect(job.mainFile == newURL.standardizedFileURL)
        #expect(Set(job.projectFiles) == [newURL.standardizedFileURL])
        #expect(Set(job.sourceOverrides.keys) == ["chapters/launch:final.tex"])

        try Data("changed after rename".utf8).write(to: newURL, options: .atomic)
        for _ in 0..<30 where editor.text != "changed after rename" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(editor.text == "changed after rename")
        #expect(!editor.isDetached)
        #expect(await structures.path == "chapters/launch:final.tex")
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

    @Test("An engine-cancelled LaTeX build releases the compiler for the next request")
    func engineCancelledLatexBuildCanRecompile() async throws {
        let fixture = try TeXEditorFixture(packageAccess: .cachedOnly)
        defer { fixture.remove() }
        let recorder = CancelThenSucceedRecorder()
        let editor = try fixture.editor(engine: CancelThenSucceedTeXEngine(recorder: recorder))

        editor.requestTeXCompile()
        await waitUntil {
            recorder.attemptCount == 1 && editor.texCompilationState == .idle
        }

        editor.requestTeXCompile()
        await waitUntil(attempts: 100) {
            recorder.attemptCount == 2 && editor.texCompilationState == .succeeded
        }

        #expect(recorder.attemptCount == 2)
        #expect(editor.texCompilationState == .succeeded)
        editor.stop()
    }

    @Test("Legacy automatic preference never builds while typing")
    func legacyAutomaticPreferenceRequiresBuildRequest() async throws {
        let fixture = try TeXEditorFixture(packageAccess: .cachedOnly)
        defer { fixture.remove() }
        let recorder = TeXJobRecorder()
        fixture.preferences.set(
            TeXCompileMode.automatic.rawValue,
            forKey: "clip.tex.compileMode"
        )
        let editor = try fixture.editor(engine: RecordingTeXEngine(recorder: recorder))
        editor.start()

        editor.text += "\n% visible edit that must wait for Build"
        try await Task.sleep(for: .milliseconds(2_700))

        #expect(recorder.job == nil)
        #expect(editor.texCompilationState == .idle)
        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .succeeded }
        #expect(recorder.job != nil)
        editor.stop()
    }

    @Test("Legacy on-save preference never builds when saving")
    func legacyOnSavePreferenceRequiresBuildRequest() async throws {
        let fixture = try TeXEditorFixture(packageAccess: .cachedOnly)
        defer { fixture.remove() }
        let recorder = TeXJobRecorder()
        fixture.preferences.set(
            TeXCompileMode.onSave.rawValue,
            forKey: "clip.tex.compileMode"
        )
        let editor = try fixture.editor(engine: RecordingTeXEngine(recorder: recorder))

        editor.text += "\n% save without building"
        editor.saveNow()
        try await Task.sleep(for: .milliseconds(250))

        #expect(recorder.job == nil)
        #expect(editor.texCompilationState == .idle)
        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .succeeded }
        #expect(recorder.job != nil)
        editor.stop()
    }

    @Test("Stopping a LaTeX editor discards queued work and late publications")
    func stoppingLatexEditorInvalidatesCompileLifecycle() async throws {
        let fixture = try TeXEditorFixture(packageAccess: .cachedOnly)
        defer { fixture.remove() }
        let recorder = HeldCompileRecorder()
        let editor = try fixture.editor(engine: HeldFirstCompileTeXEngine(recorder: recorder))

        editor.requestTeXCompile()
        await waitUntil { recorder.startedCount == 1 }
        editor.requestTeXCompile()
        editor.stop()
        recorder.releaseFirstBuild()
        try await Task.sleep(for: .milliseconds(250))

        #expect(recorder.startedCount == 1)
        #expect(editor.texCompilationState == .idle)
        #expect(editor.texPDFURL == nil)
        #expect(editor.texSyncTeXURL == nil)

        editor.requestTeXCompile()
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.startedCount == 1)
    }

    @Test("Changing the LaTeX root rejects the old build and clears PDF navigation")
    func changingMainFileInvalidatesBuildIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-tex-main-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = FileID(rawValue: "first-main")
        let secondID = FileID(rawValue: "second-main")
        let firstURL = root.appendingPathComponent("first.tex")
        let secondURL = root.appendingPathComponent("second.tex")
        let firstSource = "\\documentclass{article}\\begin{document}First\\end{document}"
        let secondSource = "\\documentclass{article}\\begin{document}Second\\end{document}"
        try Data(firstSource.utf8).write(to: firstURL)
        try Data(secondSource.utf8).write(to: secondURL)
        let document = try TextDocument(
            files: [
                TextFile(id: firstID, relativePath: "first.tex", language: .latex),
                TextFile(id: secondID, relativePath: "second.tex", language: .latex),
            ],
            mainFileID: firstID
        )
        let recorder = HeldCompileRecorder()
        let editor = TextEditorViewModel(
            document: document,
            contents: [firstID: firstSource, secondID: secondSource],
            activeFileID: firstID,
            sourceURLs: [firstID: firstURL, secondID: secondURL],
            projectFileURLs: ["first.tex": firstURL, "second.tex": secondURL],
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _, _ in },
            texPreferences: try makeTeXPreferences(packageAccess: .cachedOnly)
        )
        editor.configureTeXEngine(HeldFirstCompileTeXEngine(recorder: recorder))

        editor.requestTeXCompile()
        await waitUntil { recorder.startedCount == 1 }
        editor.setMainFile(secondID)
        recorder.releaseFirstBuild()
        try await Task.sleep(for: .milliseconds(250))

        #expect(recorder.mainFiles == ["first.tex"])
        #expect(editor.texCompilationState == .idle)
        #expect(editor.texPDFURL == nil)
        #expect(editor.texSyncTeXURL == nil)

        editor.requestTeXCompile()
        await waitUntil(attempts: 100) { editor.texCompilationState == .succeeded }
        #expect(recorder.mainFiles == ["first.tex", "second.tex"])
        #expect(editor.texPDFURL != nil)
        #expect(editor.texSyncTeXURL != nil)
        #expect(editor.texSyncTeXIndex != nil)

        editor.setMainFile(firstID)
        #expect(editor.texCompilationState == .idle)
        #expect(editor.texPDFURL == nil)
        #expect(editor.texSyncTeXURL == nil)
        #expect(editor.texSyncTeXIndex == nil)
        editor.stop()
    }

    @Test("LaTeX builds serialize and coalesce edits into one follow-up snapshot")
    func latexBuildsAreSerializedAndCoalesced() async throws {
        let fixture = try TeXEditorFixture(packageAccess: .cachedOnly)
        defer { fixture.remove() }
        let recorder = SerialCompileRecorder()
        let editor = try fixture.editor(engine: DelayedRecordingTeXEngine(recorder: recorder))

        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .compiling }
        editor.text += "% first queued edit\n"
        editor.requestTeXCompile()
        editor.text += "% second queued edit\n"
        editor.requestTeXCompile()

        await waitUntil(attempts: 100) {
            recorder.completedCount == 2 && editor.texCompilationState == .succeeded
        }
        #expect(recorder.startedCount == 2)
        #expect(recorder.maximumConcurrentCount == 1)
        #expect(recorder.latestSource?.contains("second queued edit") == true)
    }

    @Test("An unchanged LaTeX document reuses its successful PDF")
    func unchangedLatexBuildReturnsImmediately() async throws {
        let fixture = try TeXEditorFixture(packageAccess: .cachedOnly)
        defer { fixture.remove() }
        let recorder = TeXJobRecorder()
        let editor = try fixture.editor(engine: RecordingTeXEngine(recorder: recorder))

        editor.requestTeXCompile()
        await waitUntil { editor.texCompilationState == .succeeded }
        #expect(recorder.compileCount == 1)

        editor.requestTeXCompile()

        #expect(recorder.compileCount == 1)
        #expect(editor.notice == "PDF is already up to date.")
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
        let customStyleURL = root.appendingPathComponent("generated-theme.sty")
        let dynamicImageURL = root.appendingPathComponent("dynamic-figure.png")
        let mainSource = "\\documentclass{article}\\input{chapters/intro}\\bibliography{refs}"
        let chapterSource = "Included chapter"
        let bibliography = "@book{clip,title={Clip}}"
        let contents = [mainID: mainSource, chapterID: chapterSource, bibID: bibliography]
        for (url, value) in [
            (mainURL, mainSource),
            (chapterURL, chapterSource),
            (bibURL, bibliography),
            (customStyleURL, "% loaded through a macro at compile time"),
        ] {
            try Data(value.utf8).write(to: url)
        }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dynamicImageURL)
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
                "generated-theme.sty": customStyleURL,
                "dynamic-figure.png": dynamicImageURL,
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
        #expect(
            Set(job.projectFiles)
                == Set([mainURL, chapterURL, bibURL, customStyleURL, dynamicImageURL])
        )
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

    @Test("A composition commit arriving after stop persists without restarting editor work")
    func lateCompositionCommitAfterStopPersistsOnce() async throws {
        let fileID = FileID(rawValue: "late-composition")
        let file = TextFile(id: fileID, relativePath: "Untitled.txt")
        let writes = TextWriteRecorder()
        let editor = TextEditorViewModel(
            document: try TextDocument(files: [file]),
            contents: [fileID: "Draft"],
            activeFileID: fileID,
            sourceURLs: [:],
            projectFileURLs: [:],
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { id, data, _ in
                await writes.record(id, data: data)
            }
        )

        editor.stop()
        editor.text = "import SwiftUI\n\n日本語"

        for _ in 0..<50 where await writes.totalCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await writes.text(for: fileID) == "import SwiftUI\n\n日本語")
        #expect(await writes.totalCount == 1)

        // Language detection normally fires after 320 ms. A stopped editor
        // must stay quiescent even when its native view commits marked text.
        try await Task.sleep(for: .milliseconds(450))
        #expect(editor.language == .plainText)
        #expect(await writes.totalCount == 1)
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
    private var storedMainSource: String?
    private var storedCompileCount = 0

    var job: TeXJob? {
        lock.lock()
        defer { lock.unlock() }
        return storedJob
    }

    var mainSource: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedMainSource
    }

    var compileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCompileCount
    }

    func record(_ job: TeXJob) {
        lock.lock()
        storedCompileCount += 1
        storedJob = job
        storedMainSource = try? String(contentsOf: job.mainFile, encoding: .utf8)
        lock.unlock()
    }
}

private actor TextWriteRecorder {
    private var writes: [FileID: String] = [:]
    private var recordedWriteCount = 0

    var count: Int { writes.count }
    var totalCount: Int { recordedWriteCount }

    func record(_ id: FileID, data: Data) {
        recordedWriteCount += 1
        writes[id] = String(data: data, encoding: .utf8)
    }

    func text(for id: FileID) -> String? { writes[id] }
}

private actor TextDocumentRecorder {
    private var document: TextDocument?

    var path: String? { document?.files.first?.relativePath }

    func record(_ document: TextDocument) {
        self.document = document
    }
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

private final class CancelThenSucceedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int { lock.withLock { attempts } }

    func beginAttempt() -> Int {
        lock.withLock {
            attempts += 1
            return attempts
        }
    }
}

private struct CancelThenSucceedTeXEngine: TeXEngine {
    let id: EngineID = "cancel-then-succeed-test"
    let displayName = "Cancel Then Succeed Test TeX"
    let isAvailable = true
    let recorder: CancelThenSucceedRecorder

    func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        let attempt = recorder.beginAttempt()
        return AsyncThrowingStream { continuation in
            guard attempt > 1 else {
                continuation.finish(throwing: TeXEngineError.cancelled)
                return
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "clip-cancelled-tex-result-\(UUID().uuidString)",
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

private final class HeldCompileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var completed = 0
    private var isFirstBuildReleased = false
    private var storedMainFiles: [String] = []

    var startedCount: Int { lock.withLock { started } }
    var completedCount: Int { lock.withLock { completed } }
    var firstBuildIsReleased: Bool { lock.withLock { isFirstBuildReleased } }
    var mainFiles: [String] { lock.withLock { storedMainFiles } }

    func beginBuild(_ job: TeXJob) -> Int {
        lock.withLock {
            started += 1
            storedMainFiles.append(job.mainFile.lastPathComponent)
            return started
        }
    }

    func completeBuild() {
        lock.withLock { completed += 1 }
    }

    func releaseFirstBuild() {
        lock.withLock { isFirstBuildReleased = true }
    }
}

private struct HeldFirstCompileTeXEngine: TeXEngine {
    let id: EngineID = "held-first-test"
    let displayName = "Held First Test TeX"
    let isAvailable = true
    let recorder: HeldCompileRecorder

    func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        let attempt = recorder.beginBuild(job)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while attempt == 1 && !recorder.firstBuildIsReleased {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "clip-held-tex-result-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    let pdf = directory.appendingPathComponent("main.pdf")
                    try Data("%PDF-test".utf8).write(to: pdf)
                    let synctex = directory.appendingPathComponent("main.synctex.gz")
                    guard
                        let compressedSyncTeX = Data(
                            base64Encoded:
                                "H4sIADnJcmoAA0XKPQ7CMAxA4d2n6AEi6rQJdbwyMSAGflTGqEpphroVNRIIcXcQC9vTp3d4SndMbXFOtyVPwha2Mt+VLZc6zuUYs6w0PeAk+Yuwi1fJfe6i/mZEhLbY9/2SlBEu/9xMokmU4WVhsKZmakLwNhiitUfvOVCNDo3zjio0TYUEbwsfue0uVY8AAAA="
                        )
                    else { throw CocoaError(.fileReadCorruptFile) }
                    try compressedSyncTeX.write(to: synctex)
                    recorder.completeBuild()
                    continuation.yield(.finished(pdf: pdf, synctex: synctex))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class SerialCompileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximumActive = 0
    private var started = 0
    private var completed = 0
    private var source: String?

    var startedCount: Int { lock.withLock { started } }
    var completedCount: Int { lock.withLock { completed } }
    var maximumConcurrentCount: Int { lock.withLock { maximumActive } }
    var latestSource: String? { lock.withLock { source } }

    func begin(_ job: TeXJob) {
        lock.withLock {
            active += 1
            started += 1
            maximumActive = max(maximumActive, active)
            source = job.sourceOverrides["main.tex"].flatMap {
                String(data: $0, encoding: .utf8)
            }
        }
    }

    func finish() {
        lock.withLock {
            active -= 1
            completed += 1
        }
    }
}

private struct DelayedRecordingTeXEngine: TeXEngine {
    let id: EngineID = "serialized-test"
    let displayName = "Serialized Test TeX"
    let isAvailable = true
    let recorder: SerialCompileRecorder

    func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                recorder.begin(job)
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "clip-serialized-tex-result-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    let pdf = directory.appendingPathComponent("main.pdf")
                    try Data("%PDF-test".utf8).write(to: pdf)
                    recorder.finish()
                    continuation.yield(.finished(pdf: pdf, synctex: nil))
                    continuation.finish()
                } catch {
                    recorder.finish()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
