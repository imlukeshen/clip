import AppKit
import Testing

@testable import Reel

@Suite("Workspace single-key shortcuts")
@MainActor
struct WorkspaceSingleKeyShortcutTests {
    @Test("Text responders retain letters, spaces, and delete")
    func textInputSuppressesWorkspaceShortcuts() {
        #expect(!SingleKeyShortcutInputGate.allowsShortcut(firstResponder: NSTextView()))
        #expect(!SingleKeyShortcutInputGate.allowsShortcut(firstResponder: NSTextField()))
        #expect(SingleKeyShortcutInputGate.allowsShortcut(firstResponder: NSButton()))
        #expect(SingleKeyShortcutInputGate.allowsShortcut(firstResponder: nil))
    }

    @Test("Timeline keys map only without command-style modifiers")
    func timelineKeyMapping() {
        #expect(
            WorkspaceSingleKeyShortcut.command(
                charactersIgnoringModifiers: "s",
                keyCode: 1,
                modifiers: []
            ) == .toggleSnapping
        )
        #expect(
            WorkspaceSingleKeyShortcut.command(
                charactersIgnoringModifiers: "m",
                keyCode: 46,
                modifiers: [.shift]
            ) == .nextMarker
        )
        #expect(
            WorkspaceSingleKeyShortcut.command(
                charactersIgnoringModifiers: " ",
                keyCode: 49,
                modifiers: []
            ) == .togglePlayback
        )
        #expect(
            WorkspaceSingleKeyShortcut.command(
                charactersIgnoringModifiers: nil,
                keyCode: 51,
                modifiers: []
            ) == .deleteSelected
        )
        #expect(
            WorkspaceSingleKeyShortcut.command(
                charactersIgnoringModifiers: "s",
                keyCode: 1,
                modifiers: [.command]
            ) == nil
        )
    }
}
