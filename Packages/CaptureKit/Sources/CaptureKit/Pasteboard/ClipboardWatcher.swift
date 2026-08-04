@preconcurrency import AppKit
import Foundation

/// Polls the macOS pasteboard and reports everything the user copies.
///
/// macOS has no notification for pasteboard changes, so the only way to build a
/// clipboard history is to poll `changeCount`. This is the approach clipboard
/// managers such as Maccy take; it needs no entitlement and no special access.
///
/// Each change is read as a single `ClipboardChange` in the richest form on
/// offer — files over an image over text — so a Finder copy is reported as file
/// URLs rather than the path string that rides alongside them.
public actor ClipboardWatcher {
    private let pollInterval: Duration
    private let pasteboard: NSPasteboard
    private let continuation: AsyncStream<ClipboardChange>.Continuation
    private var task: Task<Void, Never>?
    private var lastChangeCount: Int
    private var selfCopyChangeCount: Int?

    /// A stream of everything copied while the watcher is running.
    public nonisolated let changes: AsyncStream<ClipboardChange>

    /// Creates a watcher.
    ///
    /// - Parameters:
    ///   - pollInterval: How often to sample `changeCount`. The default matches
    ///     the cadence a person notices as instant without spinning the CPU.
    ///   - pasteboardName: The pasteboard to watch. Defaults to the general
    ///     pasteboard; a named one lets tests drive changes in isolation.
    public init(
        pollInterval: Duration = .milliseconds(333),
        pasteboardName: NSPasteboard.Name = .general
    ) {
        let pasteboard = NSPasteboard(name: pasteboardName)
        let stream = AsyncStream<ClipboardChange>.makeStream()
        self.pollInterval = pollInterval
        self.pasteboard = pasteboard
        self.changes = stream.stream
        self.continuation = stream.continuation
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        task?.cancel()
        continuation.finish()
    }

    /// Starts polling. Calling this more than once is harmless.
    public func start() {
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
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Marks a `changeCount` value as an app-authored write so the matching
    /// change is not reported back as something the user copied.
    ///
    /// Pass the count `CapturePasteboard.write` returned: recording it before the
    /// next poll closes the window in which Clip's own paste-back would otherwise
    /// re-enter the history.
    public func markSelfCopy(expected changeCount: Int) {
        selfCopyChangeCount = changeCount
    }

    /// Samples the pasteboard once and reports a change if there is a new one.
    /// The polling loop calls this on a timer; tests call it directly to drive a
    /// change without waiting on the clock.
    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard changeCount != selfCopyChangeCount else { return }
        guard let change = read() else { return }
        continuation.yield(change)
    }

    /// Reads the current pasteboard as the richest change it offers.
    private func read() -> ClipboardChange? {
        if let urls = fileURLs(), !urls.isEmpty {
            return .fileURLs(urls)
        }
        if let png = pasteboard.data(forType: .png) {
            return .image(png, pathExtension: "png")
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            return .image(tiff, pathExtension: "tiff")
        }
        if let text = pasteboard.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .text(text)
        }
        return nil
    }

    private func fileURLs() -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }
}
