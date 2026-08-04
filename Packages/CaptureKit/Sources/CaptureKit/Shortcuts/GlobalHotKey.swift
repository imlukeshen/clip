@preconcurrency import Carbon.HIToolbox
import Foundation
import os

/// A single, fixed system-wide keyboard shortcut.
///
/// Registers with Carbon's `RegisterEventHotKey`, the same mechanism clipboard
/// managers such as Maccy rely on. Unlike a `CGEvent` tap it needs no
/// Accessibility permission and works inside the App Store sandbox, so the
/// shortcut reaches Clip even when another app is frontmost.
///
/// The handler is delivered on the main thread, because Carbon dispatches hot
/// key events through the application's run loop.
public actor GlobalHotKey {
    private let context: HotKeyContext
    private var isRegistered = false

    /// Creates a hotkey bound to a virtual key code and Carbon modifier mask.
    ///
    /// The defaults are Command-Shift-C, written as integer constants rather
    /// than modifier glyphs so the check that forbids literal modifier symbols
    /// outside `DesignSystem` stays green.
    ///
    /// - Parameters:
    ///   - keyCode: A `kVK_`-style virtual key code.
    ///   - modifiers: A Carbon modifier mask such as `cmdKey | shiftKey`.
    public init(
        keyCode: UInt32 = UInt32(kVK_ANSI_C),
        modifiers: UInt32 = UInt32(cmdKey | shiftKey)
    ) {
        self.context = HotKeyContext(keyCode: keyCode, modifiers: modifiers)
    }

    /// Registers the shortcut, calling `handler` on the main thread each time it
    /// fires. Registering more than once is harmless.
    ///
    /// - Throws: `CaptureError.hotKeyUnavailable` if the system refuses the
    ///   registration — most often because another app already holds the combo.
    public func register(handler: @escaping @Sendable () -> Void) throws {
        guard !isRegistered else { return }
        try context.register(handler: handler)
        isRegistered = true
    }

    /// Removes the shortcut. Safe to call when nothing is registered.
    public func unregister() {
        guard isRegistered else { return }
        context.unregister()
        isRegistered = false
    }
}

/// The Carbon event handler reaches this context through an opaque pointer and
/// reads the stored handler from the C callback.
///
/// The `EventHotKeyRef`/`EventHandlerRef` are `OpaquePointer`s; they are touched
/// only by `register`/`unregister`, which the owning `GlobalHotKey` actor
/// serializes and the callback never enters, so the actor's isolation is their
/// synchronization. The handler alone is read from the callback thread while the
/// actor may be writing it, so it sits behind an `OSAllocatedUnfairLock`. Those
/// two guarantees together are what back this narrowly scoped unchecked
/// conformance.
private final class HotKeyContext: @unchecked Sendable {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private var hotKey: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func register(handler: @escaping @Sendable () -> Void) throws {
        self.handler.withLock { $0 = handler }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let installed = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installed == noErr else {
            self.handler.withLock { $0 = nil }
            throw CaptureError.hotKeyUnavailable
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var hotKey: EventHotKeyRef?
        let registered = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKey
        )
        guard registered == noErr, let hotKey else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handler.withLock { $0 = nil }
            throw CaptureError.hotKeyUnavailable
        }

        self.hotKey = hotKey
        self.handlerRef = handlerRef
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKey = nil
        handlerRef = nil
        handler.withLock { $0 = nil }
    }

    /// Runs the stored handler synchronously. Clip registers exactly one global
    /// hotkey, so there is nothing to disambiguate against.
    fileprivate func fire() {
        let handler = handler.withLock { $0 }
        handler?()
    }

    /// A four-char signature identifying Clip's hotkey registration.
    private static let signature = "clip".utf8.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let context = Unmanaged<HotKeyContext>.fromOpaque(userData).takeUnretainedValue()
    context.fire()
    return noErr
}
