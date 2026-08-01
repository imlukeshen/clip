import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

@Test func imageProbeReadsDimensionsWithoutAVAssetSynchronousAccess() async throws {
    let encoded =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    let data = try #require(Data(base64Encoded: encoded))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-probe-\(UUID().uuidString).png"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)

    let result = try await AVFoundationMediaProbe().probe(url)

    #expect(result.kind == .image)
    #expect(result.width == 1)
    #expect(result.height == 1)
    #expect(result.duration == nil)
}
