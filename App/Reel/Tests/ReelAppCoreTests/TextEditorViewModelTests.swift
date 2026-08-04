import AppKit
import CoreModel
import Foundation
import Testing

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
}

@MainActor
private final class UndoBackedTextView: NSTextView {
    weak var providedUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        providedUndoManager ?? super.undoManager
    }
}
