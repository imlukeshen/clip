import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@MainActor
@Suite("File names follow their language")
struct TextFileNamingTests {
    @Test("Choosing a language renames a scratch file to match")
    func choosingLanguageRenames() throws {
        let editor = try makeScratch(named: "Untitled.txt", language: .plainText)
        editor.setLanguage(.go)
        #expect(editor.activeFile?.relativePath == "Untitled.go")
        editor.setLanguage(.python)
        #expect(editor.activeFile?.relativePath == "Untitled.py")
    }

    @Test("A named scratch file keeps its name and swaps only the extension")
    func namedScratchKeepsStem() throws {
        let editor = try makeScratch(named: "solver.py", language: .python)
        editor.setLanguage(.rust)
        #expect(editor.activeFile?.relativePath == "solver.rs")
    }

    @Test("Detection renames a scratch file as the user types")
    func detectionRenames() async throws {
        let editor = try makeScratch(named: "Untitled.txt", language: .plainText, explicit: false)
        editor.text = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(1)\n}\n"
        for _ in 0..<50 where editor.language != .go {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.language == .go)
        #expect(editor.activeFile?.relativePath == "Untitled.go")
    }

    @Test("Typing a known extension switches the language")
    func typedExtensionSetsLanguage() throws {
        let editor = try makeScratch(named: "Untitled.txt", language: .plainText)
        #expect(editor.renameActiveScratchFile(to: "server.go"))
        #expect(editor.activeFile?.relativePath == "server.go")
        #expect(editor.language == .go)
        #expect(editor.activeFile?.languageIsExplicit == true)
    }

    @Test("A name without a known extension gets the language's extension")
    func bareNameGetsExtension() throws {
        let editor = try makeScratch(named: "Untitled.py", language: .python)
        #expect(editor.renameActiveScratchFile(to: "solver"))
        #expect(editor.activeFile?.relativePath == "solver.py")
        #expect(editor.renameActiveScratchFile(to: "v1.2"))
        #expect(editor.activeFile?.relativePath == "v1.2.py")
        #expect(editor.language == .python)
    }

    @Test("Renaming and switching language undo together")
    func renameUndoesAsOneStep() throws {
        let editor = try makeScratch(named: "notes.md", language: .markdown)
        #expect(editor.renameActiveScratchFile(to: "main.c"))
        #expect(editor.language == .c)
        editor.undo()
        #expect(editor.activeFile?.relativePath == "notes.md")
        #expect(editor.language == .markdown)
    }

    private func makeScratch(
        named name: String,
        language: LanguageID,
        explicit: Bool = true
    ) throws -> TextEditorViewModel {
        let file = TextFile(
            id: FileID(rawValue: "naming-\(UUID().uuidString)"),
            relativePath: name,
            language: language,
            languageIsExplicit: explicit
        )
        return TextEditorViewModel(
            document: try TextDocument(files: [file]),
            text: "",
            sourceURL: nil,
            hashingWith: { _ in "hash" },
            persistingStructure: { _ in },
            persistingContents: { _, _ in }
        )
    }
}
