import AVFoundation
import Foundation
import XCTest

final class TextEditorTypingTests: XCTestCase {
    @MainActor
    func testClipboardShortcutOpensAndClosesTheGlobalPanel() throws {
        let app = XCUIApplication()
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-clipboard-shortcut-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertEqual(app.state, .runningForeground)
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
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
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
    }

    @MainActor
    func testCommandPaletteOpensVideoEditorAndDismissesOutside() throws {
        let (app, libraryRoot) = launchClip(named: "command-palette")
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

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
    func testMarkdownAndLaTeXPreviewsAreReachableFromScratchEditor() throws {
        let (app, libraryRoot) = launchClip(named: "text-previews")
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

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
            app.descendants(matching: .any)["markdown-split-editor"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["markdown-preview"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Clip preview"].waitForExistence(timeout: 10))

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
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        return (app, libraryRoot)
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
