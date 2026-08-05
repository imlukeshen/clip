import AppKit
import Foundation
import Testing

@testable import CaptureKit

@Suite("Clipboard watcher")
struct ClipboardWatcherTests {
    private func makeName() -> NSPasteboard.Name {
        NSPasteboard.Name("clip.test.watch.\(UUID().uuidString)")
    }

    /// Waits for the next change the watcher reports, failing if none arrives.
    private func nextChange(from watcher: ClipboardWatcher) async throws -> ClipboardChange {
        try await withThrowingTaskGroup(of: ClipboardChange?.self) { group in
            group.addTask {
                for await change in await watcher.changes { return change }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            return try #require(first ?? nil)
        }
    }

    @Test("Copied text is reported as a text change")
    func reportsText() async throws {
        let name = makeName()
        let watcher = ClipboardWatcher(pasteboardName: name)

        let board = NSPasteboard(name: name)
        board.clearContents()
        board.setString("watched words", forType: .string)

        async let change = nextChange(from: watcher)
        await watcher.poll()

        #expect(try await change == .text("watched words"))
    }

    @Test("Copied file URLs are reported as a file-set change, not their path text")
    func reportsFileURLs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("thing.txt")
        try Data("x".utf8).write(to: file)

        let name = makeName()
        let watcher = ClipboardWatcher(pasteboardName: name)

        let board = NSPasteboard(name: name)
        board.clearContents()
        board.writeObjects([file as NSURL])

        async let change = nextChange(from: watcher)
        await watcher.poll()

        guard case .fileURLs(let urls) = try await change else {
            Issue.record("expected file URLs")
            return
        }
        #expect(urls.map(\.lastPathComponent) == ["thing.txt"])
    }

    @Test("A write marked as self-authored is not reported, later copies still are")
    func suppressesSelfCopy() async throws {
        let name = makeName()
        let watcher = ClipboardWatcher(pasteboardName: name)
        let board = NSPasteboard(name: name)

        board.clearContents()
        board.setString("app authored", forType: .string)
        await watcher.markSelfCopy(expected: board.changeCount)
        await watcher.poll()  // suppressed

        board.clearContents()
        board.setString("user typed", forType: .string)

        async let change = nextChange(from: watcher)
        await watcher.poll()

        #expect(try await change == .text("user typed"))
    }

    @Test("A repeated change count is polled without reporting twice")
    func ignoresUnchangedCount() async throws {
        let name = makeName()
        let watcher = ClipboardWatcher(pasteboardName: name)
        let board = NSPasteboard(name: name)
        board.clearContents()
        board.setString("once", forType: .string)

        async let first = nextChange(from: watcher)
        await watcher.poll()
        #expect(try await first == .text("once"))

        // A second poll with no new write must not yield again; if it did, this
        // would deadlock waiting on the timeout branch instead.
        await watcher.poll()
    }
}
