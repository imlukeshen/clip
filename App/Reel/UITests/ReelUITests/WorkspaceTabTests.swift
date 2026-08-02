import XCTest

final class WorkspaceTabTests: XCTestCase {
    @MainActor
    func testRapidWorkspaceSwitchingFiftyTimes() throws {
        let app = XCUIApplication()
        app.launch()

        let workspaceNames = ["inbox", "video", "photo", "pdf", "convert"]
        XCTAssertTrue(
            app.buttons["workspace-tab-inbox"].waitForExistence(timeout: 10),
            "Reel did not expose its workspace tabs"
        )

        for iteration in 0..<50 {
            for name in workspaceNames {
                let tab = app.buttons["workspace-tab-\(name)"]
                tab.click()

                XCTAssertEqual(
                    tab.value as? String,
                    "selected",
                    "\(name) did not select on iteration \(iteration)"
                )
                XCTAssertTrue(
                    app.descendants(matching: .any)["workspace-content-\(name)"].exists,
                    "\(name) content did not appear on iteration \(iteration)"
                )
            }
        }
    }
}
