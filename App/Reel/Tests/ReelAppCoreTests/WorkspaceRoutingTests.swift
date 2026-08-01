import Testing

@testable import ReelAppCore

@Suite("Workspace routing")
struct WorkspaceRoutingTests {
    @Test(
        "Dropped files route by type instead of the active workspace",
        arguments: [
            ("walkthrough.mov", Workspace.video),
            ("capture.png", Workspace.photo),
            ("notes.pdf", Workspace.pdf),
            ("voice.m4a", Workspace.convert),
        ]
    )
    func routesByType(filename: String, expected: Workspace) {
        #expect(WorkspaceRouter.destination(forFilename: filename) == expected)
    }

    @Test("Every workspace declares a leading drop zone")
    func everyWorkspaceAcceptsDrops() {
        #expect(Workspace.allCases.allSatisfy { $0.hasDropZone })
    }
}
