import Darwin
import Dispatch
import Foundation
import LibraryStore

/// Watches the user-selected screenshot destination for completed capture files.
public actor InboxWatcher {
    private let url: URL
    private let bookmarks: BookmarkStore
    private let usesSecurityScope: Bool
    private let collector: InboxEventCollector
    private var source: DispatchSourceFileSystemObject?

    /// The directory observed by this watcher.
    public nonisolated let directoryURL: URL

    /// A stream of newly observed candidate files.
    public nonisolated let events: AsyncStream<URL>

    /// Creates an inbox watcher with an explicit extension allowlist.
    public init(
        url: URL,
        bookmarks: BookmarkStore,
        usesSecurityScope: Bool = false,
        extensions: Set<String> = ["mov", "mp4", "png", "jpg", "jpeg", "heic", "tiff"]
    ) {
        let stream = AsyncStream<URL>.makeStream()
        let standardizedURL = url.standardizedFileURL
        self.url = standardizedURL
        self.bookmarks = bookmarks
        self.usesSecurityScope = usesSecurityScope
        self.directoryURL = standardizedURL
        self.events = stream.stream
        self.collector = InboxEventCollector(
            url: standardizedURL,
            extensions: Set(extensions.map { $0.lowercased() }),
            continuation: stream.continuation
        )
    }

    deinit {
        source?.cancel()
    }

    /// Starts watching from a fresh session baseline.
    ///
    /// Files already present are deliberately ignored. Only captures that arrive while the
    /// watcher is active are emitted, so reopening the app never imports captures made while it
    /// was closed.
    public func start() async throws {
        guard source == nil else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureError.inboxUnavailable(url.path)
        }

        let didStartSecurityScope = usesSecurityScope && url.startAccessingSecurityScopedResource()
        guard !usesSecurityScope || didStartSecurityScope else {
            throw CaptureError.inboxUnavailable(url.path)
        }

        let watchedURL = url
        let descriptor = open(watchedURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            if didStartSecurityScope { url.stopAccessingSecurityScopedResource() }
            throw CaptureError.inboxUnavailable(url.path)
        }

        let collector = self.collector
        let queue = DispatchQueue(label: "app.reel.capture.inbox", qos: .utility)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: queue
        )
        source.setEventHandler {
            Task {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    await collector.scan()
                } catch {
                    // Cancellation means the watcher has stopped.
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
            if didStartSecurityScope { watchedURL.stopAccessingSecurityScopedResource() }
        }
        self.source = source
        source.resume()
        await collector.prime()
        _ = bookmarks
    }

    /// Stops watching. Calling this more than once is harmless.
    public func stop() async {
        source?.cancel()
        source = nil
        await collector.deactivate()
    }
}

private actor InboxEventCollector {
    private let url: URL
    private let extensions: Set<String>
    private let continuation: AsyncStream<URL>.Continuation
    private var seen: Set<URL> = []
    private var isActive = false

    init(
        url: URL,
        extensions: Set<String>,
        continuation: AsyncStream<URL>.Continuation
    ) {
        self.url = url
        self.extensions = extensions
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func prime() {
        seen.formUnion(candidates())
        isActive = true
    }

    func scan() {
        guard isActive else { return }
        let candidates = candidates()
        for candidate in candidates where seen.insert(candidate).inserted {
            continuation.yield(candidate)
        }
    }

    func deactivate() {
        isActive = false
    }

    private func candidates() -> [URL] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        return files.compactMap { candidate in
            let name = candidate.lastPathComponent
            guard
                !name.hasPrefix(".")
                    && !name.hasSuffix(".download")
                    && !name.hasSuffix(".tmp")
                    && extensions.contains(candidate.pathExtension.lowercased())
            else { return nil }
            return candidate.standardizedFileURL
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
