@preconcurrency import AppKit
import Foundation

/// Polls the macOS pasteboard for user-created image content.
public actor PasteboardWatcher {
    private let pollInterval: Duration
    private let continuation: AsyncStream<Data>.Continuation
    private var task: Task<Void, Never>?
    private var lastChangeCount: Int
    private var selfCopyChangeCount: Int?

    /// A stream of PNG or TIFF image payloads.
    public nonisolated let images: AsyncStream<Data>

    /// Creates a pasteboard watcher.
    public init(pollInterval: Duration = .milliseconds(333)) {
        let stream = AsyncStream<Data>.makeStream()
        self.pollInterval = pollInterval
        self.images = stream.stream
        self.continuation = stream.continuation
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    deinit {
        task?.cancel()
        continuation.finish()
    }

    /// Starts polling. Calling this more than once is harmless.
    public func start() async {
        guard task == nil else { return }
        let interval = pollInterval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops polling.
    public func stop() async {
        task?.cancel()
        task = nil
    }

    /// Marks the current pasteboard write as app-authored so it is not re-ingested.
    public func markSelfCopy() {
        selfCopyChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard changeCount != selfCopyChangeCount else { return }

        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            continuation.yield(data)
        }
    }
}
