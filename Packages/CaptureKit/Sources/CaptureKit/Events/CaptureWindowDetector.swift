@preconcurrency import AppKit
import Darwin
import Foundation

/// A completed interval in which the system `screencapture` process was present.
public struct CaptureWindow: Codable, Sendable, Equatable {
    public let start: UInt64
    public let end: UInt64
    public let startedAt: Date
    public let endedAt: Date

    public init(start: UInt64, end: UInt64, startedAt: Date, endedAt: Date) {
        self.start = start
        self.end = end
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public init(start: UInt64, end: UInt64) {
        self.init(
            start: start,
            end: end,
            startedAt: Date(timeIntervalSinceReferenceDate: HostClock.seconds(from: start)),
            endedAt: Date(timeIntervalSinceReferenceDate: HostClock.seconds(from: end))
        )
    }

    public var duration: TimeInterval {
        HostClock.seconds(from: start, to: end)
    }
}

/// Detects system capture sessions without using private APIs.
public actor CaptureWindowDetector {
    public nonisolated let windows: AsyncStream<CaptureWindow>

    private let continuation: AsyncStream<CaptureWindow>.Continuation
    private var task: Task<Void, Never>?
    private var history: [CaptureWindow] = []
    private var active: (hostTime: UInt64, wallTime: Date)?

    public init() {
        let stream = AsyncStream<CaptureWindow>.makeStream()
        self.windows = stream.stream
        self.continuation = stream.continuation
        Task { await start() }
    }

    deinit {
        continuation.finish()
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await poll()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if let active {
            finishActiveSession(active)
            self.active = nil
        }
    }

    public func recentWindows() -> [CaptureWindow] {
        history
    }

    private func poll() {
        let isRunning = Self.isScreenCaptureRunning()
        if isRunning, active == nil {
            active = (HostClock.now(), Date())
        } else if !isRunning, let active {
            finishActiveSession(active)
            self.active = nil
        }
    }

    private func finishActiveSession(_ session: (hostTime: UInt64, wallTime: Date)) {
        let window = CaptureWindow(
            start: session.hostTime,
            end: HostClock.now(),
            startedAt: session.wallTime,
            endedAt: Date()
        )
        history.append(window)
        history.removeAll { Date().timeIntervalSince($0.endedAt) > 600 }
        continuation.yield(window)
    }

    private static func isScreenCaptureRunning() -> Bool {
        let workspaceNames = NSWorkspace.shared.runningApplications.compactMap {
            $0.executableURL?.lastPathComponent.lowercased()
        }
        if containsScreenCaptureProcess(names: workspaceNames) { return true }
        return containsScreenCaptureProcess(names: processNames())
    }

    static func containsScreenCaptureProcess<S: Sequence>(names: S) -> Bool
    where S.Element == String {
        names.contains { $0.lowercased() == "screencapture" }
    }

    private static func processNames() -> [String] {
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 1)
        var pids = [pid_t](repeating: 0, count: estimatedCount + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
        return pids.prefix(count).compactMap { pid in
            guard pid > 0 else { return nil }
            var name = [CChar](repeating: 0, count: 1_024)
            let length = proc_name(pid, &name, UInt32(name.count))
            guard length > 0 else { return nil }
            return String(
                decoding: name.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
    }
}
