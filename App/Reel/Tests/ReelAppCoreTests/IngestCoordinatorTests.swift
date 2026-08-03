import CaptureKit
import CoreModel
import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

@Test func inboxCoordinatorImportsOnlyCapturesFromTheActiveSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-coordinator-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let inboxURL = LibraryLayout.inbox(in: root)
    try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    let bookmarks = BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    let library = try await LibraryStore(root: root, bookmarks: bookmarks)
    let pipeline = IngestPipeline(
        library: library,
        libraryRoot: root,
        probe: CoordinatorFixtureProbe(),
        derivatives: CoordinatorFixtureDerivatives()
    )
    let inbox = InboxWatcher(url: inboxURL, bookmarks: bookmarks, extensions: ["mov"])
    let probe = AssociationProbe()
    let coordinator = IngestCoordinator(
        pipeline: pipeline,
        inbox: inbox,
        pasteboard: PasteboardWatcher(),
        didIngest: { record, url in await probe.record(record, url: url) }
    )
    let staleSource = inboxURL.appendingPathComponent("Before Launch.mov")
    try Data(repeating: 0x30, count: 4_096).write(to: staleSource)
    try await coordinator.start()

    let source = inboxURL.appendingPathComponent("System Recording.mov")
    try Data(repeating: 0x31, count: 4_096).write(to: source)
    for _ in 0..<40 where await probe.count == 0 {
        try await Task.sleep(for: .milliseconds(100))
    }
    await coordinator.stop()

    #expect(await probe.count == 1)
    #expect(await probe.lastURL == source.standardizedFileURL)
    #expect(await probe.lastRecord?.kind == .video)
}

@Test func inboxCoordinatorAlsoWatchesTheSystemCaptureDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-system-capture-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let inboxURL = LibraryLayout.inbox(in: root)
    let systemCaptureURL = root.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: systemCaptureURL,
        withIntermediateDirectories: true
    )
    let bookmarks = BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    let library = try await LibraryStore(root: root, bookmarks: bookmarks)
    let pipeline = IngestPipeline(
        library: library,
        libraryRoot: root,
        probe: CoordinatorFixtureProbe(),
        derivatives: CoordinatorFixtureDerivatives()
    )
    let probe = AssociationProbe()
    let coordinator = IngestCoordinator(
        pipeline: pipeline,
        inboxes: [
            InboxWatcher(url: inboxURL, bookmarks: bookmarks, extensions: ["mov"]),
            InboxWatcher(url: systemCaptureURL, bookmarks: bookmarks, extensions: ["mov"]),
        ],
        pasteboard: PasteboardWatcher(),
        didIngest: { record, url in await probe.record(record, url: url) }
    )
    let activeDirectories = try await coordinator.start()

    let recording = systemCaptureURL.appendingPathComponent("Screen Recording.mov")
    try Data(repeating: 0x32, count: 4_096).write(to: recording)
    for _ in 0..<40 where await probe.count == 0 {
        try await Task.sleep(for: .milliseconds(100))
    }
    await coordinator.stop()

    #expect(await probe.count == 1)
    #expect(await probe.lastURL == recording.standardizedFileURL)
    #expect(await probe.lastRecord?.relativePath == "Media/Inbox/Screen Recording.mov")
    #expect(Set(activeDirectories) == Set([inboxURL, systemCaptureURL]))
}

@Test func inboxCoordinatorCanAddACaptureFolderWhileRunning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-granted-capture-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let inboxURL = LibraryLayout.inbox(in: root)
    let grantedCaptureURL = root.appendingPathComponent("Granted Captures", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: grantedCaptureURL,
        withIntermediateDirectories: true
    )
    let bookmarks = BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
    let library = try await LibraryStore(root: root, bookmarks: bookmarks)
    let pipeline = IngestPipeline(
        library: library,
        libraryRoot: root,
        probe: CoordinatorFixtureProbe(),
        derivatives: CoordinatorFixtureDerivatives()
    )
    let probe = AssociationProbe()
    let coordinator = IngestCoordinator(
        pipeline: pipeline,
        inbox: InboxWatcher(url: inboxURL, bookmarks: bookmarks, extensions: ["mov"]),
        pasteboard: PasteboardWatcher(),
        didIngest: { record, url in await probe.record(record, url: url) }
    )
    try await coordinator.start()
    try await coordinator.addInbox(
        InboxWatcher(url: grantedCaptureURL, bookmarks: bookmarks, extensions: ["mov"])
    )

    let recording = grantedCaptureURL.appendingPathComponent("Granted Recording.mov")
    try Data(repeating: 0x33, count: 4_096).write(to: recording)
    for _ in 0..<40 where await probe.count == 0 {
        try await Task.sleep(for: .milliseconds(100))
    }
    await coordinator.stop()

    #expect(await probe.count == 1)
    #expect(await probe.lastURL == recording.standardizedFileURL)
    #expect(await probe.lastRecord?.relativePath == "Media/Inbox/Granted Recording.mov")
}

private actor AssociationProbe {
    private(set) var records: [(AssetRecord, URL?)] = []

    var count: Int { records.count }
    var lastURL: URL? { records.last?.1 }
    var lastRecord: AssetRecord? { records.last?.0 }

    func record(_ record: AssetRecord, url: URL?) {
        records.append((record, url))
    }
}

private struct CoordinatorFixtureProbe: MediaProbing {
    func probe(_ url: URL) async throws -> MediaProbeResult {
        MediaProbeResult(
            kind: .video,
            container: "mov",
            codec: "h264",
            width: 640,
            height: 360,
            duration: RationalTime(seconds: 3),
            nominalFPS: 60,
            isVariableFPS: false,
            hasAudio: false,
            preferredTransform: nil
        )
    }
}

private struct CoordinatorFixtureDerivatives: DerivativeGenerating {
    func generate(
        for assetURL: URL,
        assetID: AssetID,
        destinationFolder: URL,
        probe: MediaProbeResult
    ) async throws -> DerivativePaths {
        .none
    }
}
