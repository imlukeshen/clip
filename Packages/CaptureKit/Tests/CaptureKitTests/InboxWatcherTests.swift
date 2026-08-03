import CaptureKit
import Foundation
import LibraryStore
import Testing

@Test func inboxWatcherEmitsAllowedFilesAndIgnoresTemporaryFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-inbox-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let watcher = InboxWatcher(
        url: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json")),
        extensions: ["mov"]
    )
    let probe = URLStreamProbe(watcher.events)
    try await watcher.start()

    try Data("partial".utf8).write(to: root.appendingPathComponent("capture.mov.tmp"))
    let capture = root.appendingPathComponent("capture.mov")
    try Data("complete".utf8).write(to: capture)

    let observed = await withTaskGroup(of: URL?.self) { group in
        group.addTask { await probe.next() }
        group.addTask {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return nil
            }
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }

    await watcher.stop()
    #expect(observed == capture.standardizedFileURL)
}

@Test func inboxWatcherIgnoresCapturesThatPredateTheActiveSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-inbox-session-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let staleCapture = root.appendingPathComponent("While Reel Was Closed.mov")
    try Data("stale".utf8).write(to: staleCapture)

    let watcher = InboxWatcher(
        url: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json")),
        extensions: ["mov"]
    )
    let probe = URLStreamProbe(watcher.events)
    try await watcher.start()

    let liveCapture = root.appendingPathComponent("While Reel Is Open.mov")
    try Data("live".utf8).write(to: liveCapture)

    let observed = await firstEvent(from: probe, timeout: .seconds(2))
    await watcher.stop()

    #expect(observed == liveCapture.standardizedFileURL)
    #expect(observed != staleCapture.standardizedFileURL)

    let stoppedCapture = root.appendingPathComponent("While Reel Is Closed Again.mov")
    try Data("stopped".utf8).write(to: stoppedCapture)
    try await watcher.start()
    let resumedCapture = root.appendingPathComponent("After Reel Reopens.mov")
    try Data("resumed".utf8).write(to: resumedCapture)
    let resumedObserved = await firstEvent(from: probe, timeout: .seconds(2))
    await watcher.stop()

    #expect(resumedObserved == resumedCapture.standardizedFileURL)
    #expect(resumedObserved != stoppedCapture.standardizedFileURL)
}

private func firstEvent(from probe: URLStreamProbe, timeout: Duration) async -> URL? {
    await withTaskGroup(of: URL?.self) { group in
        group.addTask { await probe.next() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private actor URLStreamProbe {
    private let stream: AsyncStream<URL>

    init(_ stream: AsyncStream<URL>) {
        self.stream = stream
    }

    func next() async -> URL? {
        for await value in stream {
            return value
        }
        return nil
    }
}
