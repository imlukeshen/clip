import CaptureKit
import Foundation
import LibraryStore

/// Connects capture-source streams to the two places a new file can go.
///
/// Files that appear inside the library — a drag onto the window, a copy into
/// `Media/Inbox` — are imports, and go through the ingest pipeline. Files the
/// system writes when you take a screenshot are not: they go to the capture
/// history, which expires, so using Clip does not mean everything you screenshot
/// becomes a permanent asset.
public actor IngestCoordinator {
    private let pipeline: IngestPipeline
    private var libraryInboxes: [InboxWatcher]
    private var captureInboxes: [InboxWatcher]
    private let history: CaptureHistory
    private let didIngest: @Sendable (AssetRecord, URL?) async -> Void
    private let didCapture: @Sendable (URL) async -> Void
    private var activeInboxes: [InboxWatcher] = []
    private var tasks: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - libraryInboxes: Directories inside the library. New files are imported.
    ///   - captureInboxes: The system screenshot destination. New files are staged.
    ///   - didCapture: Called with the source URL of each new system capture,
    ///     before anything is staged, so the app can route recordings to an open
    ///     editor or honour the destination preference instead.
    public init(
        pipeline: IngestPipeline,
        libraryInboxes: [InboxWatcher],
        captureInboxes: [InboxWatcher],
        history: CaptureHistory,
        didIngest: @escaping @Sendable (AssetRecord, URL?) async -> Void = { _, _ in },
        didCapture: @escaping @Sendable (URL) async -> Void = { _ in }
    ) {
        self.pipeline = pipeline
        self.libraryInboxes = libraryInboxes
        self.captureInboxes = captureInboxes
        self.history = history
        self.didIngest = didIngest
        self.didCapture = didCapture
    }

    deinit {
        for task in tasks {
            task.cancel()
        }
    }

    /// Starts every source and forwards its events until stopped.
    @discardableResult
    public func start() async throws -> [URL] {
        guard tasks.isEmpty else { return activeInboxes.map(\.directoryURL) }
        guard let primaryInbox = libraryInboxes.first else { return [] }
        // The library's own inbox is the one that has to work; a screenshot
        // folder Clip cannot reach costs the history, not importing.
        try await primaryInbox.start()
        var started = [primaryInbox]
        beginImporting(primaryInbox)

        for inbox in libraryInboxes.dropFirst() where await tryStart(inbox) {
            started.append(inbox)
            beginImporting(inbox)
        }
        for inbox in captureInboxes where await tryStart(inbox) {
            started.append(inbox)
            beginStaging(inbox)
        }
        activeInboxes = started
        return started.map(\.directoryURL)
    }

    /// Adds a library directory to watch after startup, once the user grants
    /// access to it.
    public func addInbox(_ inbox: InboxWatcher) async throws {
        guard !activeInboxes.contains(where: { $0.directoryURL == inbox.directoryURL }) else {
            return
        }
        libraryInboxes.removeAll { $0.directoryURL == inbox.directoryURL }
        libraryInboxes.append(inbox)
        guard !tasks.isEmpty else { return }
        try await inbox.start()
        activeInboxes.append(inbox)
        beginImporting(inbox)
    }

    /// Adds a system capture directory to watch after startup.
    public func addCaptureInbox(_ inbox: InboxWatcher) async throws {
        guard !activeInboxes.contains(where: { $0.directoryURL == inbox.directoryURL }) else {
            return
        }
        captureInboxes.removeAll { $0.directoryURL == inbox.directoryURL }
        captureInboxes.append(inbox)
        guard !tasks.isEmpty else { return }
        try await inbox.start()
        activeInboxes.append(inbox)
        beginStaging(inbox)
    }

    /// Stops source polling and event forwarding.
    public func stop() async {
        for task in tasks {
            task.cancel()
        }
        tasks = []
        let activeInboxes = activeInboxes
        self.activeInboxes = []
        for inbox in activeInboxes {
            await inbox.stop()
        }
    }

    private func tryStart(_ inbox: InboxWatcher) async -> Bool {
        do {
            try await inbox.start()
            return true
        } catch {
            // Best effort: a sandbox denial or a stale preference costs one
            // directory, not the session.
            return false
        }
    }

    private func beginImporting(_ inbox: InboxWatcher) {
        let events = inbox.events
        let pipeline = self.pipeline
        let didIngest = didIngest
        tasks.append(
            Task {
                for await url in events {
                    do {
                        let result = try await pipeline.ingestResult(url, source: .inbox)
                        guard result.wasInserted else { continue }
                        await didIngest(result.record, url)
                    } catch {
                        // IngestPipeline emits the typed failure event.
                    }
                }
            })
    }

    private func beginStaging(_ inbox: InboxWatcher) {
        let events = inbox.events
        let didCapture = didCapture
        tasks.append(
            Task {
                for await url in events {
                    await didCapture(url)
                }
            })
    }

    /// Copies a system capture into the history. Separate from `didCapture` so
    /// the app can decide per capture whether it wants staging at all.
    @discardableResult
    public func stage(_ url: URL) async throws -> CaptureHistoryItem {
        try await history.adopt(url)
    }
}
