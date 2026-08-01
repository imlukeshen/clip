import Darwin
import Dispatch
import Foundation
import LibraryStore

/// Watches the user-selected screenshot destination for completed capture files.
public actor InboxWatcher {
    private let url: URL
    private let bookmarks: BookmarkStore
    private let collector: InboxEventCollector
    private var source: DispatchSourceFileSystemObject?

    /// A stream of newly observed candidate files.
    public nonisolated let events: AsyncStream<URL>

    /// Creates an inbox watcher with an explicit extension allowlist.
    public init(
        url: URL,
        bookmarks: BookmarkStore,
        extensions: Set<String> = ["mov", "mp4", "png", "jpg", "jpeg", "heic", "tiff"]
    ) {
        let stream = AsyncStream<URL>.makeStream()
        self.url = url.standardizedFileURL
        self.bookmarks = bookmarks
        self.events = stream.stream
        self.collector = InboxEventCollector(
            url: url.standardizedFileURL,
            extensions: Set(extensions.map { $0.lowercased() }),
            continuation: stream.continuation
        )
    }

    deinit {
        source?.cancel()
    }

    /// Starts watching and performs an initial catch-up scan.
    public func start() async throws {
        guard source == nil else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureError.inboxUnavailable(url.path)
        }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
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
        }
        self.source = source
        source.resume()
        await collector.scan()
        _ = bookmarks
    }

    /// Stops watching. Calling this more than once is harmless.
    public func stop() async {
        source?.cancel()
        source = nil
    }
}

private actor InboxEventCollector {
    private let url: URL
    private let extensions: Set<String>
    private let continuation: AsyncStream<URL>.Continuation
    private var seen: Set<URL> = []

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

    func scan() {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return
        }

        let candidates = files.filter { candidate in
            let name = candidate.lastPathComponent
            return !name.hasPrefix(".")
                && !name.hasSuffix(".download")
                && !name.hasSuffix(".tmp")
                && extensions.contains(candidate.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for candidate in candidates where seen.insert(candidate.standardizedFileURL).inserted {
            continuation.yield(candidate.standardizedFileURL)
        }
    }
}
