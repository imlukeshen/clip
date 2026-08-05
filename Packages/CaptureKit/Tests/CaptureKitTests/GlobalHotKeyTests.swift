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
    private let testModifiers = UInt32(cmdKey | shiftKey | controlKey | optionKey)

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
            modifiers: testModifiers
        )
    }

    private func sendHotKeyEvent(keyCode: Int) {
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
        guard let event else { return }
        defer { ReleaseEvent(event) }

        let signature = "clip".utf8.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
        var hotKeyID = EventHotKeyID(
            signature: signature,
            id: UInt32(keyCode) | testModifiers
        )
        #expect(
            SetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size,
                &hotKeyID
            ) == noErr
        )
        #expect(SendEventToEventTarget(event, GetEventDispatcherTarget()) == noErr)
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
        let keyCode = kVK_F17
        let hotKey = makeHotKey(keyCode: keyCode)
        let probe = DeliveryProbe()
        try hotKey.register {
            Task { await probe.record() }
        }

        sendHotKeyEvent(keyCode: keyCode)

        for _ in 0..<20 where !(await probe.wasDelivered) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.wasDelivered)
        hotKey.unregister()
    }

    @Test("Distinct hot keys deliver only to their matching handler")
    func disambiguatesRegisteredHotKeys() async throws {
        let firstKeyCode = kVK_F16
        let secondKeyCode = kVK_F15
        let first = makeHotKey(keyCode: firstKeyCode)
        let second = makeHotKey(keyCode: secondKeyCode)
        let firstProbe = DeliveryProbe()
        let secondProbe = DeliveryProbe()
        try first.register { Task { await firstProbe.record() } }
        try second.register { Task { await secondProbe.record() } }
        defer {
            first.unregister()
            second.unregister()
        }

        sendHotKeyEvent(keyCode: secondKeyCode)
        for _ in 0..<20 where !(await secondProbe.wasDelivered) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!(await firstProbe.wasDelivered))
        #expect(await secondProbe.wasDelivered)
    }
}
