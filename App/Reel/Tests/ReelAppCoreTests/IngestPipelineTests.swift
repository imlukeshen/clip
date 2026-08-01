import CoreModel
import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

@Test func stableCaptureImportsWithinTwoSecondsAndDeduplicates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-pipeline-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let inbox = root.appendingPathComponent("Incoming", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let source = inbox.appendingPathComponent("Screen Recording.mov")
    try Data(repeating: 0x42, count: 64 * 1_024).write(to: source)

    let library = try await LibraryStore(
        root: root,
        bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    )
    let pipeline = IngestPipeline(
        library: library,
        libraryRoot: root,
        probe: FixtureProbe(),
        derivatives: FixtureDerivatives()
    )
    let clock = ContinuousClock()
    let start = clock.now

    let first = try await pipeline.ingest(source, source: .inbox)
    let elapsed = start.duration(to: clock.now)
    let second = try await pipeline.ingest(source, source: .drop)

    #expect(elapsed < .seconds(2))
    #expect(first == second)
    #expect(first.displayName == "Screen Recording.mov")
    #expect(first.kind == .video)
    #expect(first.thumbnailPath != nil)
    #expect(first.peaksPath != nil)
    #expect(try await library.assets(kind: nil, limit: 10, offset: 0).count == 1)
    let importedURL = try await library.url(for: first.id)
    let permissions = try FileManager.default.attributesOfItem(atPath: importedURL.path)
    let mode = try #require(permissions[.posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o222 == 0)
}

private struct FixtureProbe: MediaProbing {
    func probe(_ url: URL) async throws -> MediaProbeResult {
        MediaProbeResult(
            kind: .video,
            container: "mov",
            codec: "h264",
            width: 1_920,
            height: 1_080,
            duration: RationalTime(seconds: 3),
            nominalFPS: 60,
            isVariableFPS: false,
            hasAudio: true,
            preferredTransform: .object([
                "a": .number(1),
                "b": .number(0),
                "c": .number(0),
                "d": .number(1),
                "tx": .number(0),
                "ty": .number(0),
            ])
        )
    }
}

private struct FixtureDerivatives: DerivativeGenerating {
    func generate(
        for assetURL: URL,
        assetID: AssetID,
        destinationFolder: URL,
        probe: MediaProbeResult
    ) async throws -> DerivativePaths {
        let thumbnail = destinationFolder.appendingPathComponent("\(assetID.rawValue).thumb.heic")
        let peaks = destinationFolder.appendingPathComponent("\(assetID.rawValue).peaks.bin")
        try Data("thumbnail".utf8).write(to: thumbnail)
        try Data("peaks".utf8).write(to: peaks)
        return DerivativePaths(thumbnail: thumbnail, peaks: peaks)
    }
}
