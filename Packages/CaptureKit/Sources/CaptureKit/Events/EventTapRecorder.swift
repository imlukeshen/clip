@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Keeps a rolling, opt-in record of mouse movement and clicks.
public actor EventTapRecorder {
    private let context: EventTapContext
    private var isRunning = false

    public init(bufferDuration: Duration = .seconds(300)) {
        let components = bufferDuration.components
        let seconds = max(
            1,
            Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
        self.context = EventTapContext(bufferDuration: seconds)
    }

    public static func isAuthorized() -> Bool {
        AXIsProcessTrusted()
    }

    public static func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public func start() async throws {
        guard !isRunning else { return }
        guard Self.isAuthorized() else { throw CaptureError.accessibilityDenied }
        try await context.start()
        isRunning = true
    }

    public func stop() async {
        guard isRunning else { return }
        context.stop()
        isRunning = false
    }

    public func slice(from start: UInt64, to end: UInt64) async -> [RawEvent] {
        context.slice(from: start, to: end)
    }
}

/// The Core Graphics C callback and dedicated `Thread` both retain this context.
/// Every mutable field is protected by an `OSAllocatedUnfairLock`, which is the
/// synchronization guarantee behind this narrowly scoped unchecked conformance.
private final class EventTapContext: @unchecked Sendable {
    private struct BufferState: Sendable {
        var slots: [RawEvent?]
        var nextIndex = 0
        var count = 0
        var overflowClicks: [RawEvent] = []
        var lastMovementTime: UInt64?
        var lastPruneTime: UInt64?
    }

    private let bufferDuration: Double
    private let buffer: OSAllocatedUnfairLock<BufferState>
    private let lifecycle = OSAllocatedUnfairLock<LifecycleState>(initialState: LifecycleState())

    private struct LifecycleState {
        var tap: CFMachPort?
        var runLoop: CFRunLoop?
    }

    init(bufferDuration: Double) {
        self.bufferDuration = bufferDuration
        let capacity = max(256, Int((bufferDuration * 120).rounded(.up)))
        self.buffer = OSAllocatedUnfairLock(
            initialState: BufferState(slots: Array(repeating: nil, count: capacity))
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { [self] in
                run(continuation: continuation)
            }
        }
    }

    func stop() {
        let values = lifecycle.withLock { ($0.tap, $0.runLoop) }
        if let tap = values.0 { CFMachPortInvalidate(tap) }
        if let runLoop = values.1 { CFRunLoopStop(runLoop) }
    }

    func slice(from start: UInt64, to end: UInt64) -> [RawEvent] {
        buffer.withLock { state in
            (state.slots.compactMap { $0 } + state.overflowClicks)
                .filter { $0.machHostTime >= start && $0.machHostTime <= end }
                .sorted { lhs, rhs in
                    if lhs.machHostTime == rhs.machHostTime {
                        return lhs.kind.rawValue < rhs.kind.rawValue
                    }
                    return lhs.machHostTime < rhs.machHostTime
                }
        }
    }

    private func run(continuation: CheckedContinuation<Void, any Error>) {
        let mask = [
            CGEventType.mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .scrollWheel,
        ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: eventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            continuation.resume(throwing: CaptureError.eventTapUnavailable)
            return
        }
        let runLoop = CFRunLoopGetCurrent()
        lifecycle.withLock {
            $0.tap = tap
            $0.runLoop = runLoop
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        continuation.resume()
        CFRunLoopRun()
        lifecycle.withLock {
            $0.tap = nil
            $0.runLoop = nil
        }
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let tap = lifecycle.withLock { $0.tap }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let kind = RawEvent.Kind(type) else { return }
        let hostTime = HostClock.now()
        let raw = RawEvent(
            machHostTime: hostTime,
            wallTime: Date(),
            location: event.location,
            kind: kind,
            clickCount: Int(event.getIntegerValueField(.mouseEventClickState))
        )
        append(raw)
    }

    private func append(_ event: RawEvent) {
        buffer.withLock { state in
            if event.kind == .mouseMoved,
                let last = state.lastMovementTime,
                HostClock.seconds(from: last, to: event.machHostTime) < (1 / 60)
            {
                return
            }
            if event.kind == .mouseMoved { state.lastMovementTime = event.machHostTime }

            if state.lastPruneTime.map({
                HostClock.seconds(from: $0, to: event.machHostTime) >= 1
            }) ?? true {
                let cutoffSeconds = HostClock.seconds(from: event.machHostTime) - bufferDuration
                for index in state.slots.indices {
                    guard let stored = state.slots[index] else { continue }
                    if HostClock.seconds(from: stored.machHostTime) < cutoffSeconds {
                        state.slots[index] = nil
                        state.count -= 1
                    }
                }
                state.overflowClicks.removeAll {
                    HostClock.seconds(from: $0.machHostTime) < cutoffSeconds
                }
                state.lastPruneTime = event.machHostTime
            }

            if state.count < state.slots.count {
                for offset in state.slots.indices {
                    let index = (state.nextIndex + offset) % state.slots.count
                    if state.slots[index] == nil {
                        state.slots[index] = event
                        state.nextIndex = (index + 1) % state.slots.count
                        state.count += 1
                        return
                    }
                }
            }

            if let movementIndex = oldestMovementIndex(in: state.slots) {
                state.slots[movementIndex] = event
                state.nextIndex = (movementIndex + 1) % state.slots.count
            } else if event.isClick {
                state.overflowClicks.append(event)
            }
        }
    }

    private func oldestMovementIndex(in slots: [RawEvent?]) -> Int? {
        slots.indices
            .filter { slots[$0]?.kind == .mouseMoved }
            .min { lhs, rhs in
                (slots[lhs]?.machHostTime ?? .max) < (slots[rhs]?.machHostTime ?? .max)
            }
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<EventTapContext>.fromOpaque(userInfo).takeUnretainedValue()
    context.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

extension RawEvent.Kind {
    fileprivate init?(_ type: CGEventType) {
        switch type {
        case .mouseMoved: self = .mouseMoved
        case .leftMouseDown: self = .leftMouseDown
        case .leftMouseUp: self = .leftMouseUp
        case .rightMouseDown: self = .rightMouseDown
        case .rightMouseUp: self = .rightMouseUp
        case .scrollWheel: self = .scrollWheel
        default: return nil
        }
    }
}
