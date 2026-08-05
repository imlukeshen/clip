import CaptureKit
import CoreModel
import Foundation
import Testing

@testable import ReelAppCore

@MainActor
@Suite("App model file rename")
struct AppModelFileRenameTests {
    @Test("An open library text file stays editable after a Finder-style rename")
    func renamesOpenLibraryTextFileAndRebasesItsEditor() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-app-model-rename-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let libraryRoot = fixtureRoot.appendingPathComponent("Library", isDirectory: true)
        let importRoot = fixtureRoot.appendingPathComponent("Import", isDirectory: true)
        try FileManager.default.createDirectory(
            at: importRoot,
            withIntermediateDirectories: true
        )
        let sourceURL = importRoot.appendingPathComponent("Draft Notes.md")
        try "# Draft\n\nReady to rename.\n".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )

        let model = AppModel(
            libraryRoot: libraryRoot,
            shortcutReader: ShortcutReader(sandboxed: true)
        )
        await model.start()
        model.accept([sourceURL], source: .drop)

        try await waitUntil {
            model.ingestCount == 0 && model.assets.count == 1
        }
        let original = try #require(model.assets.first)
        #expect(original.kind == .text)
        #expect(original.displayName == "Draft Notes.md")

        let originalLibraryURL = libraryRoot.appendingPathComponent(original.relativePath)
        #expect(FileManager.default.fileExists(atPath: originalLibraryURL.path))

        model.openTextEditor(for: original.id)
        try await waitUntil { model.textEditor != nil }
        let editor = try #require(model.textEditor)
        #expect(editor.sourceURL?.standardizedFileURL == originalLibraryURL.standardizedFileURL)

        // Omitting the extension mirrors Finder: the existing `.md` suffix is retained.
        model.renameOpenTextFile(to: "Renamed Notes")
        try await waitUntil {
            model.assets.first(where: { $0.id == original.id })?.displayName
                == "Renamed Notes.md"
                && editor.sourceURL?.lastPathComponent == "Renamed Notes.md"
        }

        let renamed = try #require(model.assets.first(where: { $0.id == original.id }))
        let renamedLibraryURL = libraryRoot.appendingPathComponent(renamed.relativePath)
        #expect(renamed.id == original.id)
        #expect(renamed.displayName == "Renamed Notes.md")
        #expect(renamedLibraryURL.pathExtension == "md")
        #expect(!FileManager.default.fileExists(atPath: originalLibraryURL.path))
        #expect(FileManager.default.fileExists(atPath: renamedLibraryURL.path))
        #expect(editor.sourceURL?.standardizedFileURL == renamedLibraryURL.standardizedFileURL)
        #expect(editor.activeFile?.relativePath == "Renamed Notes.md")

        #expect(editor.undoManager.canUndo)
        _ = AppCommandRouter.run("edit.undo", in: model)
        #expect(!model.renamingAssetIDs.isEmpty)
        #expect(
            AppCommandRouter.availability(of: "edit.redo", in: model)
                == .unavailable(reason: "Wait for the file rename to finish.")
        )
        // A rapid shortcut repeat must not consume the synchronously prepared
        // Redo entry while the filesystem move is still running.
        _ = AppCommandRouter.run("edit.redo", in: model)
        #expect(editor.undoManager.canRedo)
        try await waitUntil {
            model.renamingAssetIDs.isEmpty
                && model.assets.first(where: { $0.id == original.id })?.displayName
                    == "Draft Notes.md"
                && editor.sourceURL?.standardizedFileURL
                    == originalLibraryURL.standardizedFileURL
        }
        #expect(editor.undoManager.canRedo)

        _ = AppCommandRouter.run("edit.redo", in: model)
        try await waitUntil {
            model.renamingAssetIDs.isEmpty
                && model.assets.first(where: { $0.id == original.id })?.displayName
                    == "Renamed Notes.md"
                && editor.sourceURL?.standardizedFileURL
                    == renamedLibraryURL.standardizedFileURL
        }

        let revisedText = "# Renamed\n\nEditing still works after the move.\n"
        editor.text = revisedText
        editor.saveNow()
        try await waitUntil {
            (try? String(contentsOf: renamedLibraryURL, encoding: .utf8)) == revisedText
        }

        #expect(!editor.isDetached)
        #expect(editor.sourceURL?.standardizedFileURL == renamedLibraryURL.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: originalLibraryURL.path))

        // Give this next rename its own undo identity. If its source disappears
        // before undo, Clip must remove only the failed inverse and preserve the
        // earlier valid rename in the same editor history.
        model.renameOpenTextFile(to: "Final Notes")
        try await waitUntil {
            model.assets.first(where: { $0.id == original.id })?.displayName
                == "Final Notes.md"
                && editor.sourceURL?.lastPathComponent == "Final Notes.md"
        }
        let final = try #require(model.assets.first(where: { $0.id == original.id }))
        let finalLibraryURL = libraryRoot.appendingPathComponent(final.relativePath)
        #expect(editor.undoManager.canUndo)

        try FileManager.default.removeItem(at: finalLibraryURL)
        _ = AppCommandRouter.run("edit.undo", in: model)
        try await waitUntil {
            model.renamingAssetIDs.isEmpty
                && model.lastMessage
                    == "The file could not be renamed. Choose a different name."
        }
        #expect(!editor.undoManager.canRedo)
        #expect(editor.undoManager.canUndo)
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(8),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw AppModelRenameTestTimeout() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private struct AppModelRenameTestTimeout: Error {}
