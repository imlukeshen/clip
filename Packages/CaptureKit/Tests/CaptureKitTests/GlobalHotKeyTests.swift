import Carbon.HIToolbox
import Foundation
import Testing

@testable import CaptureKit

// Serialized because a global hotkey is process-wide: two tests registering
// concurrently would contend for the same system slot. Each test also uses a
// distinct combo so a leaked registration cannot poison its neighbour.
@Suite("Global hot key", .serialized)
@MainActor
struct GlobalHotKeyTests {
    private actor DeliveryProbe {
        private(set) var wasDelivered = false

        func record() {
            wasDelivered = true
        }
    }

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
    func registerUnregisterLifecycle() throws {
        let hotKey = makeHotKey(keyCode: kVK_F19)

        try hotKey.register {}
        // A second register is a no-op rather than a duplicate registration.
        try hotKey.register {}

        hotKey.unregister()
        // Unregistering twice must not trap on the already-freed references.
        hotKey.unregister()
    }

    @Test("A second GlobalHotKey on the same combo reports it is unavailable")
    func rejectsDuplicateRegistration() throws {
        let first = makeHotKey(keyCode: kVK_F18)
        try first.register {}

        let second = makeHotKey(keyCode: kVK_F18)
        #expect(throws: CaptureError.hotKeyUnavailable) {
            try second.register {}
        }

        first.unregister()
    }

    @Test("Hot-key events reach the registered application handler")
    func deliversApplicationEvent() async throws {
        let hotKey = makeHotKey(keyCode: kVK_F17)
        let probe = DeliveryProbe()
        try hotKey.register {
            Task { await probe.record() }
        }

        var event: EventRef?
        let created = CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(),
            0,
            &event
        )
        #expect(created == noErr)
        if let event {
            #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
            ReleaseEvent(event)
        }

        for _ in 0..<20 where !(await probe.wasDelivered) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.wasDelivered)
        hotKey.unregister()
    }
}
