import Foundation
import Testing
@testable import ReelAppCore

@Test @MainActor func newAndExistingLibrariesUseTheCorrectBrandedFolder() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-branding-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let clip = parent.appendingPathComponent("Clip", isDirectory: true)
    let reel = parent.appendingPathComponent("Reel", isDirectory: true)
    #expect(AppModel.preferredAppDirectory(in: parent) == clip)

    try FileManager.default.createDirectory(at: reel, withIntermediateDirectories: true)
    #expect(AppModel.preferredAppDirectory(in: parent) == reel)

    try FileManager.default.createDirectory(at: clip, withIntermediateDirectories: true)
    #expect(AppModel.preferredAppDirectory(in: parent) == clip)
}
