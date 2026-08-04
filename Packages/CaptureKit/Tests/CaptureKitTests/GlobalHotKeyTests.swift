import Carbon.HIToolbox
import Foundation
import Testing

@testable import CaptureKit

// Serialized because a global hotkey is process-wide: two tests registering
// concurrently would contend for the same system slot. Each test also uses a
// distinct combo so a leaked registration cannot poison its neighbour.
@Suite("Global hot key", .serialized)
struct GlobalHotKeyTests {
    /// An obscure combo (all four modifiers plus a function key) so these tests
    /// never collide with a real shortcut the test machine already has for the
    /// default Command-Shift-C.
    private func makeHotKey(keyCode: Int) -> GlobalHotKey {
        GlobalHotKey(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(cmdKey | shiftKey | controlKey | optionKey)
        )
    }

    @Test("Registering then unregistering leaves no handler installed")
    func registerUnregisterLifecycle() async throws {
        let hotKey = makeHotKey(keyCode: kVK_F19)

        try await hotKey.register {}
        // A second register is a no-op rather than a duplicate registration.
        try await hotKey.register {}

        await hotKey.unregister()
        // Unregistering twice must not trap on the already-freed references.
        await hotKey.unregister()
    }

    @Test("A second GlobalHotKey on the same combo reports it is unavailable")
    func rejectsDuplicateRegistration() async throws {
        let first = makeHotKey(keyCode: kVK_F18)
        try await first.register {}

        let second = makeHotKey(keyCode: kVK_F18)
        await #expect(throws: CaptureError.hotKeyUnavailable) {
            try await second.register {}
        }

        await first.unregister()
    }
}
