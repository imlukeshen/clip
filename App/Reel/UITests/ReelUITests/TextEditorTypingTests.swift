import AVFoundation
import AppKit
import CoreImage
import Foundation
import XCTest

final class TextEditorTypingTests: XCTestCase {
    @MainActor
    func testClipboardRowPastesIntoTheActiveTextEditor() throws {
        let app = XCUIApplication()
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-clipboard-paste-\(UUID().uuidString)",
            isDirectory: true
        )
        try seedTextHistory("one-click paste", in: libraryRoot)
        defer {
            NSPasteboard.general.clearContents()
            try? FileManager.default.removeItem(at: libraryRoot)
        }
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-clip.globalClipboardShortcutEnabled", "YES",
        ]
        app.launch()

        let textRoute = app.buttons["sidebar-route-text"]
        XCTAssertTrue(textRoute.waitForExistence(timeout: 10))
        textRoute.click()
        let newScratch = app.buttons["text-new-scratch"]
        XCTAssertTrue(newScratch.waitForExistence(timeout: 5))
        newScratch.click()
        let editor = app.textViews["text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()

        // Open from Clip's menu so this paste-behaviour test remains isolated
        // from global shortcut ownership (for example, when Maccy owns ⌘⇧C).
        app.menuBars.menuBarItems["Capture"].click()
        let openClipboard = app.menuItems["Open Clip Clipboard"]
        XCTAssertTrue(openClipboard.waitForExistence(timeout: 2))
        openClipboard.click()
        let pasteRow = app.buttons["Paste one-click paste"]
        XCTAssertTrue(pasteRow.waitForExistence(timeout: 5))
        pasteRow.click()

        let deadline = Date().addingTimeInterval(5)
        while (editor.value as? String) != "one-click paste", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(editor.value as? String, "one-click paste")
        XCTAssertTrue(app.staticTexts["Clip Clipboard"].waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testClipboardShortcutOpensAndEscapeClosesTheGlobalPanel() throws {
        let app = XCUIApplication()
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-clipboard-shortcut-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            NSPasteboard.general.clearContents()
            try? FileManager.default.removeItem(at: libraryRoot)
        }
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-clip.globalClipboardShortcutEnabled", "YES",
        ]
        app.launch()

        XCTAssertEqual(app.state, .runningForeground)
        app.typeKey("c", modifierFlags: [.command, .shift])

        let clipboardTitle = app.staticTexts["Clip Clipboard"]
        XCTAssertTrue(clipboardTitle.waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(clipboardTitle.waitForNonExistence(timeout: 5))

        // Command-Shift-C remains a toggle when the user invokes it again.
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(clipboardTitle.waitForExistence(timeout: 5))
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(clipboardTitle.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testClipboardShortcutCanBeReleasedForAnotherClipboardManager() throws {
        let (app, libraryRoot) = launchClip(named: "clipboard-shortcut-setting")
        defer {
            NSPasteboard.general.clearContents()
            try? FileManager.default.removeItem(at: libraryRoot)
        }

        XCTAssertTrue(app.buttons["sidebar-route-all-media"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let toggle = app.descendants(matching: .any)["settings-global-clipboard-shortcut"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()

        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertFalse(app.staticTexts["Clip Clipboard"].waitForExistence(timeout: 2))

        app.activate()
        toggle.click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        let clipboardTitle = app.staticTexts["Clip Clipboard"]
        XCTAssertTrue(clipboardTitle.waitForExistence(timeout: 5))
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(clipboardTitle.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testScratchEditorAcceptsTypingAndUndo() throws {
        let app = XCUIApplication()
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-text-editor-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            NSPasteboard.general.clearContents()
            try? FileManager.default.removeItem(at: libraryRoot)
        }
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let textRoute = app.buttons["sidebar-route-text"]
        XCTAssertTrue(textRoute.waitForExistence(timeout: 10))
        textRoute.click()

        let newScratch = app.buttons["text-new-scratch"]
        XCTAssertTrue(newScratch.waitForExistence(timeout: 5))
        newScratch.click()

        let editor = app.textViews["text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Clip typing works")
        XCTAssertEqual(editor.value as? String, "Clip typing works")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "")

        editor.typeText("import SwiftUI\n\n@main struct ClipApp: App {}")
        let languageMenu = app.descendants(matching: .any)["text-language-menu"]
        XCTAssertTrue(languageMenu.waitForExistence(timeout: 5))
        let detectionDeadline = Date().addingTimeInterval(5)
        while !languageMenu.label.contains("Swift"), Date() < detectionDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(languageMenu.label.contains("Swift"))

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey(.delete, modifierFlags: [])

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Clip paste works", forType: .string)
        app.activate()
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "Clip paste works")
    }

    @MainActor
    func testCommandPaletteOpensVideoEditorAndDismissesOutside() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-command-palette-\(UUID().uuidString)",
            isDirectory: true
        )
        let libraryRoot = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let videoURL = temporaryRoot.appendingPathComponent("Pasted Video.mov")
        let imageURL = temporaryRoot.appendingPathComponent("Pasted Photo.png")
        try FileManager.default.createDirectory(
            at: temporaryRoot, withIntermediateDirectories: true)
        try makeTestRecording(at: videoURL)
        try makeTestImage(at: imageURL)
        defer {
            NSPasteboard.general.clearContents()
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let app = XCUIApplication()
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-clip.globalClipboardShortcutEnabled", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["sidebar-route-all-media"].waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)

        let palette = app.descendants(matching: .any)["command-palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        let videoCommand = app.buttons["command-navigation.video"]
        XCTAssertTrue(videoCommand.waitForExistence(timeout: 5))
        videoCommand.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace-content-video"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["video-empty-timeline"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["sidebar-route-all-media"].waitForNonExistence(timeout: 5),
            "The library sidebar should retract while the video editor is open"
        )
        for identifier in [
            "video-tool-select",
            "video-tool-razor",
            "video-tool-snapping",
            "video-tool-split",
            "video-tool-delete",
            "video-tool-ripple-delete",
            "video-tool-separate-audio",
            "video-tool-nest",
            "video-tool-marker",
            "video-tool-zoom",
            "video-tool-auto-zoom",
        ] {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5),
                "Missing accessible editor tool: \(identifier)"
            )
        }
        XCTAssertTrue(
            waitForTimelineItemCount(0, in: app, timeout: 5),
            "The empty timeline did not report zero items"
        )
        let timeline = app.descendants(matching: .any)["video-timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            timeline.frame.maxY,
            app.windows.firstMatch.frame.maxY + 1,
            "The video timeline must stay inside the dynamically sized window"
        )
        let projectTitle = app.buttons["video-project-title"]
        XCTAssertTrue(projectTitle.waitForExistence(timeout: 5))
        projectTitle.click()
        let projectTitleField = app.textFields["video-project-title-field"]
        XCTAssertTrue(projectTitleField.waitForExistence(timeout: 5))
        projectTitleField.typeKey("a", modifierFlags: .command)
        projectTitleField.typeText("Launch Cut")
        projectTitleField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(projectTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(projectTitle.label, "Rename project Launch Cut")

        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([videoURL as NSURL]))
        app.activate()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(
            waitForTimelineItemCount(1, in: app, timeout: 20),
            "Command-V did not add the pasted video to the empty timeline"
        )

        let deleteTool = app.descendants(matching: .any)["video-tool-delete"]
        deleteTool.click()
        XCTAssertTrue(
            waitForTimelineItemCount(0, in: app, timeout: 5),
            "Deleting the selected final clip did not empty the timeline"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["video-empty-timeline"]
                .waitForExistence(timeout: 5)
        )

        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([videoURL as NSURL]))
        app.activate()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(
            waitForTimelineItemCount(1, in: app, timeout: 20),
            "Command-V did not add media again after deleting the final clip"
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try Data(contentsOf: imageURL), forType: .png)
        app.activate()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(
            waitForTimelineItemCount(2, in: app, timeout: 20),
            "Command-V did not turn the pasted photo into a timeline clip"
        )

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.55))
            .click()
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testLibraryRenameMovesThePhysicalFileAndUpdatesItsVisibleName() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-library-rename-\(UUID().uuidString)",
            isDirectory: true
        )
        let libraryRoot = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let imageURL = temporaryRoot.appendingPathComponent("Rename Fixture.png")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        try makeTestImage(at: imageURL)
        defer {
            NSPasteboard.general.clearContents()
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let app = XCUIApplication()
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.buttons["sidebar-route-all-media"].waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let palette = app.descendants(matching: .any)["command-palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        let videoCommand = app.buttons["command-navigation.video"]
        XCTAssertTrue(videoCommand.waitForExistence(timeout: 5))
        videoCommand.click()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try Data(contentsOf: imageURL), forType: .png)
        app.activate()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(
            waitForTimelineItemCount(1, in: app, timeout: 20),
            "The fixture image was not imported into the library-backed timeline"
        )

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        let mediaCommand = app.buttons["command-navigation.inbox"]
        XCTAssertTrue(mediaCommand.waitForExistence(timeout: 5))
        mediaCommand.click()

        let originalAsset = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset-card-")
        ).firstMatch
        XCTAssertTrue(originalAsset.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForLabelPrefix("Pasted Image.mov,", on: originalAsset, timeout: 5),
            "The imported asset did not publish its canonical filename"
        )
        let assetIdentifier = originalAsset.identifier
        originalAsset.click()
        let renameButton = app.buttons["asset-rename-button"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5))
        renameButton.click()

        // Native SwiftUI alerts are exposed as sheets on hosted macOS and may
        // strip identifiers from their text fields. Scope the query to the
        // presented sheet so it remains stable across macOS accessibility roles.
        let renameAlert = app.sheets.firstMatch
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(renameAlert.staticTexts["Rename File"].exists)
        let renameField = renameAlert.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Renamed Still")
        renameAlert.buttons["Rename"].click()

        let renamedAsset = app.buttons[assetIdentifier]
        XCTAssertTrue(
            waitForLabelPrefix("Renamed Still.mov,", on: renamedAsset, timeout: 10),
            "The library did not publish the canonical renamed filename"
        )
        let originalURL = libraryRoot.appendingPathComponent("Media/Inbox/Pasted Image.mov")
        let renamedURL = libraryRoot.appendingPathComponent("Media/Inbox/Renamed Still.mov")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: renamedURL.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
    }

    @MainActor
    func testLibrarySearchResignsFocusOnOutsideClick() throws {
        let (app, libraryRoot) = launchClip(named: "search-focus")
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let search = app.textFields["library-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("needle")
        XCTAssertEqual(search.value as? String, "needle")

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.70))
            .click()
        app.typeKey("x", modifierFlags: [])
        XCTAssertEqual(search.value as? String, "needle")
    }

    @MainActor
    func testMarkdownWritingSurfaceAndLaTeXPreviewAreReachableFromScratchEditor() throws {
        let (app, libraryRoot) = launchClip(named: "text-previews")
        defer {
            NSPasteboard.general.clearContents()
            try? FileManager.default.removeItem(at: libraryRoot)
        }

        XCTAssertTrue(app.buttons["sidebar-route-text"].waitForExistence(timeout: 10))
        app.buttons["sidebar-route-text"].click()
        XCTAssertTrue(app.buttons["text-new-scratch"].waitForExistence(timeout: 5))
        app.buttons["text-new-scratch"].click()

        let editor = app.textViews["text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("# Clip preview")

        let languageMenu = app.descendants(matching: .any)["text-language-menu"]
        XCTAssertTrue(languageMenu.waitForExistence(timeout: 5))
        languageMenu.click()
        XCTAssertTrue(app.menuItems["Markdown"].waitForExistence(timeout: 5))
        app.menuItems["Markdown"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["markdown-inline-editor"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["markdown-formatting-toolbar"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["markdown-bold"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["markdown-bulleted-list"].exists)

        let blockStyle = app.descendants(matching: .any)["markdown-block-style"]
        XCTAssertTrue(
            blockStyle.label.contains("Heading 1"),
            "Expected Heading 1 toolbar state, got: \(blockStyle.label)"
        )
        editor.click()
        editor.typeKey(.end, modifierFlags: .command)
        editor.typeText("\n")
        blockStyle.click()
        XCTAssertTrue(app.menuItems["Heading 1"].waitForExistence(timeout: 5))
        app.menuItems["Heading 1"].click()
        editor.typeText("Persistent heading")
        XCTAssertTrue((editor.value as? String ?? "").contains("# Persistent heading"))
        XCTAssertTrue(
            blockStyle.label.contains("Heading 1"),
            "Expected Heading 1 toolbar state after typing, got: \(blockStyle.label)"
        )

        editor.click()
        editor.typeKey(.end, modifierFlags: .command)
        editor.typeText("\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "import SwiftUI\n\nstruct ClipCard: View {\n    var body: some View { Text(\"Clip\") }\n}",
            forType: .string
        )
        app.activate()
        editor.typeKey("v", modifierFlags: .command)
        let pasteDeadline = Date().addingTimeInterval(5)
        while !(editor.value as? String ?? "").contains("```swift"), Date() < pasteDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let markdown = editor.value as? String ?? ""
        XCTAssertTrue(markdown.contains("```swift"))
        XCTAssertTrue(markdown.contains("struct ClipCard: View"))
        XCTAssertTrue(markdown.contains("\n```"))

        languageMenu.click()
        XCTAssertTrue(app.menuItems["LaTeX"].waitForExistence(timeout: 5))
        app.menuItems["LaTeX"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["latex-split-editor"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["latex-compile"].waitForExistence(timeout: 5))

        // Choosing LaTeX from the language menu must return focus to the
        // source. Do not click the editor again: this is the exact menu-driven
        // transition that previously left its TextKit viewport unpainted.
        let latexEditor = app.textViews["text-editor"]
        latexEditor.typeKey(.end, modifierFlags: .command)
        latexEditor.typeText("\n% visible after choosing LaTeX")
        XCTAssertTrue(
            (latexEditor.value as? String ?? "").contains("% visible after choosing LaTeX")
        )
    }

    @MainActor
    func testLaTeXEditorAcceptsTypingAfterEnteringTheSplitWorkspace() throws {
        let (app, libraryRoot) = launchClip(named: "latex-typing")
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        XCTAssertTrue(app.buttons["sidebar-route-text"].waitForExistence(timeout: 10))
        app.buttons["sidebar-route-text"].click()
        XCTAssertTrue(app.buttons["text-new-scratch"].waitForExistence(timeout: 5))
        app.buttons["text-new-scratch"].click()

        let editor = app.textViews["text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\\documentclass{article}")

        XCTAssertTrue(
            app.descendants(matching: .any)["latex-split-editor"].waitForExistence(timeout: 5)
        )

        // The same native editor must retain the prefix and remain the typing
        // target after the PDF preview is inserted beside it.
        let latexEditor = app.textViews["text-editor"]
        XCTAssertTrue(latexEditor.waitForExistence(timeout: 5))
        latexEditor.typeKey(.end, modifierFlags: .command)
        latexEditor.typeText("\n\\begin{document}\nClip typing works\n\\end{document}")

        XCTAssertEqual(
            latexEditor.value as? String,
            "\\documentclass{article}\n\\begin{document}\nClip typing works\n\\end{document}"
        )
    }

    @MainActor
    func testLaTeXSourceBuildsAndDisplaysAPDF() throws {
        let (app, libraryRoot) = launchClip(
            named: "latex-pdf",
            arguments: [
                "-clip.tex.packageAccess", "allowNetwork",
            ]
        )
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        XCTAssertTrue(app.buttons["sidebar-route-text"].waitForExistence(timeout: 10))
        app.buttons["sidebar-route-text"].click()
        XCTAssertTrue(app.buttons["text-new-scratch"].waitForExistence(timeout: 5))
        app.buttons["text-new-scratch"].click()

        let editor = app.textViews["text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText(
            "\\documentclass{article}\n\\begin{document}\nClip PDF\n\\end{document}"
        )

        // Scratch buffers detect LaTeX from their contents and promote the
        // default filename to a TeX main file without a manual language choice.
        XCTAssertTrue(
            app.descendants(matching: .any)["latex-split-editor"]
                .waitForExistence(timeout: 5)
        )

        // Even a legacy automatic preference must not start compilation from
        // typing. The source stays interactive and the preview waits for Build.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.staticTexts["Not built"].exists)
        XCTAssertEqual(
            app.textViews["text-editor"].value as? String,
            "\\documentclass{article}\n\\begin{document}\nClip PDF\n\\end{document}"
        )

        let buildButton = app.buttons["latex-compile"]
        XCTAssertTrue(buildButton.waitForExistence(timeout: 5))
        buildButton.click()

        XCTAssertTrue(
            app.staticTexts["PDF ready"].waitForExistence(timeout: 90),
            "LaTeX did not compile into the PDF preview"
        )
        XCTAssertTrue(app.staticTexts["Clip PDF"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNewScreenRecordingAutomaticallyOpensTheTimeline() throws {
        let app = XCUIApplication()
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-recording-route-\(UUID().uuidString)",
            isDirectory: true
        )
        let libraryRoot = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let captureSource = temporaryRoot.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureSource,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let stagingURL = captureSource.appendingPathComponent("recording.tmp")
        try makeTestRecording(at: stagingURL)

        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launchEnvironment["REEL_CAPTURE_SOURCE"] = captureSource.path
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-reel.captureDestination", "timeline",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar-route-all-media"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)

        let recordingURL = captureSource.appendingPathComponent("Screen Recording Test.mov")
        try FileManager.default.moveItem(at: stagingURL, to: recordingURL)

        XCTAssertTrue(
            waitForTimelineItemCount(1, in: app, timeout: 30),
            "A new recording did not open the timeline editor"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["video-timeline"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    private func waitForLabelPrefix(
        _ prefix: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        guard element.waitForExistence(timeout: min(timeout, 5)) else { return false }
        let labelMatches = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let expectation = XCTNSPredicateExpectation(predicate: labelMatches, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForTimelineItemCount(
        _ expectedCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let status = app.descendants(matching: .any)["video-timeline-item-count"]
        guard status.waitForExistence(timeout: min(timeout, 5)) else { return false }
        // SwiftUI's generic accessibility element drops AXValue on some macOS
        // releases, while AXLabel is consistently available.
        let labelMatches = NSPredicate(
            format: "label == %@",
            "Timeline items: \(expectedCount)"
        )
        let expectation = XCTNSPredicateExpectation(predicate: labelMatches, object: status)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func launchClip(
        named name: String,
        arguments: [String] = []
    ) -> (XCUIApplication, URL) {
        let app = XCUIApplication()
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launchArguments +=
            [
                "-ApplePersistenceIgnoreState", "YES",
                "-clip.globalClipboardShortcutEnabled", "YES",
            ] + arguments
        app.launch()
        return (app, libraryRoot)
    }

    private func makeTestImage(at url: URL) throws {
        let image = CIImage(color: .cyan).cropped(
            to: CGRect(x: 0, y: 0, width: 96, height: 64)
        )
        try CIContext().writePNGRepresentation(
            of: image,
            to: url,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
    }

    private func seedTextHistory(_ text: String, in libraryRoot: URL) throws {
        let directory = libraryRoot.appendingPathComponent(".reel/history", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString).txt"
        try Data(text.utf8).write(
            to: directory.appendingPathComponent(fileName),
            options: .atomic
        )
        let item = SeedCaptureHistoryItem(
            id: id,
            fileName: fileName,
            displayName: text,
            kind: "text",
            capturedAt: Date(),
            byteSize: Int64(text.utf8.count),
            preview: text,
            contentHash: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode([item]).write(
            to: directory.appendingPathComponent("index.json"),
            options: .atomic
        )
    }

    private func makeTestRecording(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        guard writer.canAdd(input) else {
            throw NSError(domain: "ClipUITests", code: 1)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ClipUITests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "ClipUITests", code: 3)
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
            throw writer.error ?? NSError(domain: "ClipUITests", code: 4)
        }
        input.markAsFinished()

        let didFinish = XCTestExpectation(description: "Finish test recording")
        writer.finishWriting { didFinish.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [didFinish], timeout: 10), .completed)
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ClipUITests", code: 5)
        }
    }
}

private struct SeedCaptureHistoryItem: Codable {
    let id: UUID
    let fileName: String
    let displayName: String
    let kind: String
    let capturedAt: Date
    let byteSize: Int64
    let preview: String?
    let contentHash: String?
}
