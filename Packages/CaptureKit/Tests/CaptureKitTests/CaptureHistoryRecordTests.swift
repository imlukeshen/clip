import Foundation
import Testing

@testable import CaptureKit

@Suite("Capture history recording")
struct CaptureHistoryRecordTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Recorded text round-trips through a backing file")
    func recordsText() async throws {
        let history = CaptureHistory(directory: try makeDirectory())

        let item = try await history.record(text: "hello clipboard")

        #expect(item.kind == .text)
        #expect(item.displayName == "hello clipboard")
        #expect(item.contentHash != nil)
        let backing = try String(contentsOf: history.url(for: item), encoding: .utf8)
        #expect(backing == "hello clipboard")
        #expect(await history.items().map(\.id) == [item.id])
    }

    @Test("The row title is the first non-empty line, clipped")
    func textTitleIsFirstLine() async throws {
        let history = CaptureHistory(directory: try makeDirectory())
        let text = "\n\n  first line  \nsecond line"

        let item = try await history.record(text: text)

        #expect(item.displayName == "first line")
    }

    @Test("Copying the same text twice bumps the existing entry instead of duplicating")
    func dedupBumpsHead() async throws {
        let history = CaptureHistory(directory: try makeDirectory())
        let old = Date(timeIntervalSinceNow: -60)
        let new = Date()

        let first = try await history.record(text: "same", capturedAt: old)
        let second = try await history.record(text: "same", capturedAt: new)

        #expect(second.id == first.id)
        #expect(second.capturedAt == new)
        #expect(await history.items().count == 1)
    }

    @Test("Different text after the same text adds a second entry")
    func differentTextAddsEntry() async throws {
        let history = CaptureHistory(directory: try makeDirectory())

        _ = try await history.record(text: "one")
        _ = try await history.record(text: "two")

        #expect(await history.items().count == 2)
    }

    @Test("Text repeated after something else is not treated as a duplicate of the head")
    func dedupOnlyMatchesHead() async throws {
        let history = CaptureHistory(directory: try makeDirectory())

        _ = try await history.record(text: "a")
        _ = try await history.record(text: "b")
        _ = try await history.record(text: "a")

        // "a" is not at the head when it repeats, so it is a fresh entry.
        #expect(await history.items().count == 3)
    }

    @Test("A recorded file list stores paths and survives a reopen")
    func recordsFileList() async throws {
        let directory = try makeDirectory()
        let history = CaptureHistory(directory: directory)
        let urls = [
            URL(fileURLWithPath: "/tmp/one.txt"),
            URL(fileURLWithPath: "/tmp/two.txt"),
        ]

        let item = try await history.record(fileURLs: urls)

        #expect(item.kind == .fileList)
        #expect(item.displayName == "2 files")
        #expect(item.canSaveToLibrary == false)
        let reopened = CaptureHistory(directory: directory)
        #expect(await reopened.items().map(\.id) == [item.id])
        let backing = try String(contentsOf: history.url(for: item), encoding: .utf8)
        #expect(backing == "/tmp/one.txt\n/tmp/two.txt")
    }

    @Test("A single-file list is titled with the file's name")
    func singleFileListLabel() async throws {
        let history = CaptureHistory(directory: try makeDirectory())

        let item = try await history.record(fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")])

        #expect(item.displayName == "report.pdf")
    }

    @Test("Recorded image bytes are stored under the right extension")
    func recordsImageData() async throws {
        let history = CaptureHistory(directory: try makeDirectory())
        let data = Data([0x89, 0x50, 0x4E, 0x47])

        let item = try await history.record(
            imageData: data,
            pathExtension: "png",
            displayName: "Pasted image"
        )

        #expect(item.kind == .image)
        #expect(history.url(for: item).pathExtension == "png")
        #expect(try Data(contentsOf: history.url(for: item)) == data)
    }

    @Test("Old index.json without the new fields still decodes")
    func decodesLegacyIndex() throws {
        let legacy = """
            [{"byteSize":10,"capturedAt":0,"displayName":"old.png",\
            "fileName":"x.png","id":"\(UUID().uuidString)","kind":"image"}]
            """
        let items = try JSONDecoder().decode(
            [CaptureHistoryItem].self,
            from: Data(legacy.utf8)
        )
        #expect(items.count == 1)
        #expect(items[0].preview == nil)
        #expect(items[0].contentHash == nil)
    }
}
