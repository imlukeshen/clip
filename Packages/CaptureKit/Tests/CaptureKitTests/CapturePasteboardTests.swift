import AppKit
import Foundation
import Testing

@testable import CaptureKit

@Suite("Capture pasteboard")
struct CapturePasteboardTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-pasteboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func namedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("clip.test.\(UUID().uuidString)"))
    }

    @Test("Writing a still puts both the file URL and the image on the pasteboard")
    func writesImageAndURL() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("shot.png")
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let png = try #require(bitmap?.representation(using: .png, properties: [:]))
        try png.write(to: url)

        let pasteboard = namedPasteboard()
        _ = CapturePasteboard.write(url, kind: .image, to: pasteboard)

        #expect(NSImage(pasteboard: pasteboard) != nil)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.contains(url) == true)
    }

    @Test("Writing a recording puts the file URL on the pasteboard but no image")
    func writesURLOnlyForVideo() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("clip.mov")
        try Data("recording".utf8).write(to: url)

        let pasteboard = namedPasteboard()
        _ = CapturePasteboard.write(url, kind: .video, to: pasteboard)

        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.contains(url) == true)
        #expect(NSImage(pasteboard: pasteboard) == nil)
    }

    @Test("Writing a text entry puts the string on the pasteboard, not a file URL")
    func writesTextAsString() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("entry.txt")
        try Data("copied words".utf8).write(to: url)

        let pasteboard = namedPasteboard()
        _ = CapturePasteboard.write(url, kind: .text, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "copied words")
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.isEmpty ?? true)
    }

    @Test("Writing a file-set entry puts the still-present file URLs on the pasteboard")
    func writesFileList() throws {
        let directory = try makeDirectory()
        let present = directory.appendingPathComponent("here.txt")
        try Data("x".utf8).write(to: present)
        let missing = directory.appendingPathComponent("gone.txt")
        let list = directory.appendingPathComponent("entry.filelist")
        try Data("\(present.path)\n\(missing.path)".utf8).write(to: list)

        let pasteboard = namedPasteboard()
        _ = CapturePasteboard.write(list, kind: .fileList, to: pasteboard)

        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.map(\.path) == [present.path])
    }

    @Test("The returned change count matches the pasteboard after the write")
    func returnsChangeCount() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("clip.mov")
        try Data("recording".utf8).write(to: url)

        let pasteboard = namedPasteboard()
        let reported = CapturePasteboard.write(url, kind: .video, to: pasteboard)

        #expect(reported == pasteboard.changeCount)
    }
}
