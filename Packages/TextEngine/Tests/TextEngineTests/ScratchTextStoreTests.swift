import CoreModel
import Foundation
import Testing

@testable import TextEngine

@Test func scratchBuffersPersistAndRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-scratch-store-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScratchTextStore(directory: root)

    let created = try await store.create()
    #expect(created.document.files.count == 1)
    #expect(created.contents.text.isEmpty)

    var document = created.document
    document.files[0].relativePath = "Ideas.md"
    try await store.save(document: document)
    try await store.save(contents: Data("# Clip\n".utf8), for: document.id)

    let records = try await store.records()
    #expect(records.map(\.name) == ["Ideas.md"])
    let restored = try await store.load(document.id)
    #expect(restored?.document == document)
    #expect(restored?.contents.text == "# Clip\n")
}

@Test func incompleteScratchBuffersAreNotListed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-incomplete-scratch-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScratchTextStore(directory: root)
    let created = try await store.create()
    try FileManager.default.removeItem(at: await store.contentURL(for: created.document.id))

    #expect(try await store.records().isEmpty)
    #expect(try await store.load(created.document.id) == nil)
}

@Test func malformedScratchDocumentsReportATypedError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-malformed-scratch-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordURL = root.appendingPathComponent("broken.reeltext")
    try Data("not json".utf8).write(to: recordURL)
    let store = ScratchTextStore(directory: root)

    await #expect(throws: TextEngineError.self) {
        try await store.records()
    }
}
