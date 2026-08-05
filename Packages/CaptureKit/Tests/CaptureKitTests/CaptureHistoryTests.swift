import Foundation
import Testing

@testable import CaptureKit

@Suite("Capture history")
struct CaptureHistoryTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCapture(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("capture".utf8).write(to: url)
        return url
    }

    @Test("Adopting a capture copies it and leaves the original in place")
    func adoptCopies() async throws {
        let root = try makeDirectory()
        let source = try writeCapture(named: "Screenshot.png", in: root)
        let history = CaptureHistory(directory: root.appendingPathComponent("history"))

        let item = try await history.adopt(source)

        #expect(item.kind == .image)
        #expect(item.displayName == "Screenshot.png")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: history.url(for: item).path))
        #expect(await history.items().map(\.id) == [item.id])
    }

    @Test("A format the history cannot preview is refused")
    func refusesUnsupported() async throws {
        let root = try makeDirectory()
        let source = try writeCapture(named: "notes.txt", in: root)
        let history = CaptureHistory(directory: root.appendingPathComponent("history"))

        await #expect(throws: CaptureError.unsupportedCapture("notes.txt")) {
            try await history.adopt(source)
        }
    }

    @Test("Entries pushed past the limit have their copies deleted")
    func prunesFiles() async throws {
        let root = try makeDirectory()
        let history = CaptureHistory(
            directory: root.appendingPathComponent("history"),
            limit: CaptureHistoryLimit(maximumCount: 1, maximumAge: 3600)
        )
        let first = try await history.adopt(try writeCapture(named: "one.png", in: root))
        let second = try await history.adopt(try writeCapture(named: "two.png", in: root))

        #expect(await history.items().map(\.id) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: history.url(for: first).path))
        #expect(FileManager.default.fileExists(atPath: history.url(for: second).path))
    }

    @Test("Clearing removes every entry and its copy, but not the originals")
    func clearKeepsOriginals() async throws {
        let root = try makeDirectory()
        let source = try writeCapture(named: "Screenshot.png", in: root)
        let history = CaptureHistory(directory: root.appendingPathComponent("history"))
        let item = try await history.adopt(source)

        await history.clear()

        #expect(await history.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: history.url(for: item).path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Entries survive a restart of the store")
    func persistsAcrossInstances() async throws {
        let root = try makeDirectory()
        let directory = root.appendingPathComponent("history")
        let source = try writeCapture(named: "Screenshot.png", in: root)
        let item = try await CaptureHistory(directory: directory).adopt(source)

        let reopened = CaptureHistory(directory: directory)

        #expect(await reopened.items().map(\.id) == [item.id])
    }

    @Test("An entry whose file was deleted by hand disappears from the list")
    func dropsMissingFiles() async throws {
        let root = try makeDirectory()
        let directory = root.appendingPathComponent("history")
        let history = CaptureHistory(directory: directory)
        let item = try await history.adopt(try writeCapture(named: "Screenshot.png", in: root))
        try FileManager.default.removeItem(at: history.url(for: item))

        #expect(await CaptureHistory(directory: directory).items().isEmpty)
    }
}
