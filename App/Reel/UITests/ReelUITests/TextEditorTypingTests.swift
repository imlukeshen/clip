import Foundation
import XCTest

final class TextEditorTypingTests: XCTestCase {
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
}
