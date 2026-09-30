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

    let clipx = parent.appendingPathComponent("clipx", isDirectory: true)
    let clip = parent.appendingPathComponent("Clip", isDirectory: true)
    let reel = parent.appendingPathComponent("Reel", isDirectory: true)

    // Nothing on disk yet: a new library takes the current name.
    #expect(AppModel.preferredAppDirectory(in: parent) == clipx)

    // Each earlier name keeps its library in place, newest first, so renaming
    // the app never looks like the library was emptied.
    try FileManager.default.createDirectory(at: reel, withIntermediateDirectories: true)
    #expect(AppModel.preferredAppDirectory(in: parent) == reel)

    try FileManager.default.createDirectory(at: clip, withIntermediateDirectories: true)
    #expect(AppModel.preferredAppDirectory(in: parent) == clip)

    try FileManager.default.createDirectory(at: clipx, withIntermediateDirectories: true)
    #expect(AppModel.preferredAppDirectory(in: parent) == clipx)
}
