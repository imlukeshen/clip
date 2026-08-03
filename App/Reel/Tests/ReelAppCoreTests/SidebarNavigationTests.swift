import CaptureKit
import Foundation
import Testing
@testable import ReelAppCore

@Test @MainActor func sidebarRoutesSwitchWorkspacesFiftyTimesWithoutDroppingState() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-sidebar-navigation-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryRoot: root, shortcutReader: ShortcutReader(sandboxed: true))

    for _ in 0..<50 {
        for workspace in [Workspace.inbox, .video, .photo, .pdf, .convert] {
            model.showWorkspace(workspace)
            #expect(model.selectedWorkspace == workspace)
        }
    }
}
