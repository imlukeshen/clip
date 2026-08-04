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

        app.typeKey("c", modifierFlags: [.command, .shift])
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
        XCTAssertTrue(app.staticTexts["0 clips"].waitForExistence(timeout: 5))

        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([videoURL as NSURL]))
        app.activate()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["1 clip"].waitForExistence(timeout: 20),
            "Command-V did not add the pasted video to the empty timeline"
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try Data(contentsOf: imageURL), forType: .png)
        app.activate()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["2 clips"].waitForExistence(timeout: 20),
            "Command-V did not turn the pasted photo into a timeline clip"
        )

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.55))
            .click()
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
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
    }

    @MainActor
    func testLaTeXSourceBuildsAndDisplaysAPDF() throws {
        let (app, libraryRoot) = launchClip(
            named: "latex-pdf",
            arguments: ["-clip.tex.packageAccess", "allowNetwork"]
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

        let languageMenu = app.popUpButtons["text-language-menu"]
        XCTAssertTrue(languageMenu.waitForExistence(timeout: 5))
        languageMenu.click()
        XCTAssertTrue(app.menuItems["LaTeX"].waitForExistence(timeout: 5))
        app.menuItems["LaTeX"].click()

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
            app.staticTexts["1 clip"].waitForExistence(timeout: 30),
            "A new recording did not open the timeline editor"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["video-timeline"].waitForExistence(timeout: 5)
        )
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
