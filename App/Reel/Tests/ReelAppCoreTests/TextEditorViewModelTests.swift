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

@MainActor
private final class UndoBackedTextView: NSTextView {
    weak var providedUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        providedUndoManager ?? super.undoManager
    }
}
