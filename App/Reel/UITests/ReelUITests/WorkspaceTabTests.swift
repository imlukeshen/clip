import Foundation
import XCTest

final class WorkspaceTabTests: XCTestCase {
    @MainActor
    func testRapidSidebarWorkspaceSwitchingFiftyTimes() throws {
        let app = XCUIApplication()
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-workspace-tabs-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        app.launchEnvironment["CLIP_UI_TESTING"] = "1"
        app.launchEnvironment["REEL_LIBRARY_ROOT"] = libraryRoot.path
        app.launch()

        let routes = [
            (button: "sidebar-route-all-media", workspace: "inbox"),
            (button: "sidebar-route-videos", workspace: "video"),
            (button: "sidebar-route-photos", workspace: "photo"),
            (button: "sidebar-route-pdfs", workspace: "pdf"),
            (button: "sidebar-route-convert", workspace: "convert"),
        ]
        XCTAssertTrue(
            app.buttons["sidebar-route-all-media"].waitForExistence(timeout: 10),
            "Clip did not expose its sidebar navigation"
        )

        for iteration in 0..<50 {
            for route in routes {
                app.buttons[route.button].click()
                XCTAssertTrue(
                    app.descendants(matching: .any)["workspace-content-\(route.workspace)"]
                        .waitForExistence(timeout: 1),
                    "\(route.workspace) content did not appear on iteration \(iteration)"
                )
            }
        }
    }
}
