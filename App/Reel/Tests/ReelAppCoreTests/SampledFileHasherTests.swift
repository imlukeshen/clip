import Foundation
import Testing

@testable import ReelAppCore

@Test func sampledHashUsesOnlyFileEdgesAndSize() throws {
    let root = try temporaryDirectory(named: "hash")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.mov")
    let second = root.appendingPathComponent("second.mov")
    var bytes = Data(repeating: 0x11, count: 3 * 1_024 * 1_024)
    try bytes.write(to: first)
    bytes.replaceSubrange(1_200_000..<1_200_010, with: Data(repeating: 0xAA, count: 10))
    try bytes.write(to: second)

    #expect(try SampledFileHasher.hash(first) == SampledFileHasher.hash(second))

    bytes[0] = 0xBB
    try bytes.write(to: second)
    #expect(try SampledFileHasher.hash(first) != SampledFileHasher.hash(second))
}

private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-ingest-tests-\(name)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
