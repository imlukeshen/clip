import CaptureKit
import CoreModel
import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

private struct CoordinatorFixture {
    let root: URL
    let inboxURL: URL
    let library: LibraryStore
    let pipeline: IngestPipeline
    let history: CaptureHistory
    let bookmarks: BookmarkStore

    init(named name: String) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        inboxURL = LibraryLayout.inbox(in: root)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        bookmarks = BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        library = try await LibraryStore(root: root, bookmarks: bookmarks)
        pipeline = IngestPipeline(
            library: library,
            libraryRoot: root,
            probe: CoordinatorFixtureProbe(),
            derivatives: CoordinatorFixtureDerivatives()
        )
        history = CaptureHistory(directory: LibraryLayout.captureHistory(in: root))
    }

    func watcher(_ url: URL) -> InboxWatcher {
        InboxWatcher(url: url, bookmarks: bookmarks, extensions: ["mov"])
    }
}

@Test func inboxCoordinatorDoesNotRepublishAClipOwnedRename() async throws {
    let fixture = try await CoordinatorFixture(named: "clip-coordinator-rename-tests")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let probe = AssociationProbe()
    let coordinator = IngestCoordinator(
        pipeline: fixture.pipeline,
        libraryInboxes: [fixture.watcher(fixture.inboxURL)],
        captureInboxes: [],
        history: fixture.history,
        didIngest: { record, url in await probe.record(record, url: url) }
    )
    try await coordinator.start()

    let source = fixture.inboxURL.appendingPathComponent("Original.mov")
    try Data(repeating: 0x35, count: 4_096).write(to: source)
    for _ in 0..<40 where await probe.count == 0 {
        try await Task.sleep(for: .milliseconds(100))
    }
    let original = try #require(await probe.lastRecord)

    let folders = LibraryFolders(root: fixture.root, library: fixture.library)
    let renamed = try await folders.renameAsset(original.id, to: "Renamed.mov")
    try await Task.sleep(for: .seconds(1))
    await coordinator.stop()

    #expect(renamed.displayName == "Renamed.mov")
    #expect(await probe.count == 1)
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(renamed.relativePath).path
        )
    )
}

@Test func inboxCoordinatorImportsOnlyCapturesFromTheActiveSession() async throws {
    let fixture = try await CoordinatorFixture(named: "reel-coordinator-tests")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let probe = AssociationProbe()
    let coordinator = IngestCoordinator(
        pipeline: fixture.pipeline,
        libraryInboxes: [fixture.watcher(fixture.inboxURL)],
        captureInboxes: [],
        history: fixture.history,
        didIngest: { record, url in await probe.record(record, url: url) }
    )
    let staleSource = fixture.inboxURL.appendingPathComponent("Before Launch.mov")
    try Data(repeating: 0x30, count: 4_096).write(to: staleSource)
    try await coordinator.start()

    let source = fixture.inboxURL.appendingPathComponent("System Recording.mov")
    try Data(repeating: 0x31, count: 4_096).write(to: source)
    for _ in 0..<40 where await probe.count == 0 {
        try await Task.sleep(for: .milliseconds(100))
    }
    await coordinator.stop()

    #expect(await probe.count == 1)
    #expect(await probe.lastURL == source.standardizedFileURL)
    #expect(await probe.lastRecord?.kind == .video)
}

/// The point of the split: a screenshot the system writes is offered to the app,
/// not imported. Nothing reaches the library unless the user asks for it.
@Test func systemCapturesAreOfferedToTheAppInsteadOfImported() async throws {
    let fixture = try await CoordinatorFixture(named: "reel-system-capture-tests")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let systemCaptureURL = fixture.root.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(
        at: systemCaptureURL,
        withIntermediateDirectories: true
    )
    let probe = AssociationProbe()
    let captures = CaptureProbe()
    let coordinator = IngestCoordinator(
        pipeline: fixture.pipeline,
        libraryInboxes: [fixture.watcher(fixture.inboxURL)],
        captureInboxes: [fixture.watcher(systemCaptureURL)],
        history: fixture.history,
        didIngest: { record, url in await probe.record(record, url: url) },
        didCapture: { url in await captures.record(url) }
    )
    let activeDirectories = try await coordinator.start()

    let recording = systemCaptureURL.appendingPathComponent("Screen Recording.mov")
    try Data(repeating: 0x32, count: 4_096).write(to: recording)
    for _ in 0..<40 where await captures.count == 0 {
        try await Task.sleep(for: .milliseconds(100))
    }
    await coordinator.stop()

    #expect(await captures.urls == [recording.standardizedFileURL])
    #expect(await probe.count == 0)
    #expect(Set(activeDirectories) == Set([fixture.inboxURL, systemCaptureURL]))
}

@Test func stagingACaptureCopiesItIntoTheHistory() async throws {
    let fixture = try await CoordinatorFixture(named: "reel-staging-tests")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let coordinator = IngestCoordinator(
        pipeline: fixture.pipeline,
        libraryInboxes: [fixture.watcher(fixture.inboxURL)],
        captureInboxes: [],
        history: fixture.history
    )
    let source = fixture.root.appendingPathComponent("Shot.png")
    try Data(repeating: 0x34, count: 512).write(to: source)

    let item = try await coordinator.stage(source)

    #expect(item.kind == .image)
    #expect(await fixture.history.items().map(\.id) == [item.id])
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func inboxCoordinatorCanAddACaptureFolderWhileRunning() async throws {
    let fixture = try await CoordinatorFixture(named: "reel-granted-capture-tests")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let grantedCaptureURL = fixture.root.appendingPathComponent(
        "Granted Captures",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: grantedCaptureURL,
        withIntermediateDirectories: true
    )
    let captures = CaptureProbe()
    let coordinator = IngestCoordinator(
        pipeline: fixture.pipeline,
        libraryInboxes: [fixture.watcher(fixture.inboxURL)],
        captureInboxes: [],
        history: fixture.history,
        didCapture: { url in await captures.record(url) }
    )
    try await coordinator.start()
    try await coordinator.addCaptureInbox(fixture.watcher(grantedCaptureURL))

    let recording = grantedCaptureURL.appendingPathComponent("Granted Recording.mov")
    try Data(repeating: 0x33, count: 4_096).write(to: recording)
    for _ in 0..<40 where await captures.count == 0 {
        try await Task.sleep(for: .milliseconds(100))
    }
    await coordinator.stop()

    #expect(await captures.urls == [recording.standardizedFileURL])
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

private actor CaptureProbe {
    private(set) var urls: [URL] = []

    var count: Int { urls.count }

    func record(_ url: URL) {
        urls.append(url)
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
