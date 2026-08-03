import CaptureKit
import Foundation
import LibraryStore

/// Connects capture-source streams to the single ingest pipeline.
public actor IngestCoordinator {
    private let pipeline: IngestPipeline
    private var inboxes: [InboxWatcher]
    private let pasteboard: PasteboardWatcher
    private let didIngest: @Sendable (AssetRecord, URL?) async -> Void
    private var activeInboxes: [InboxWatcher] = []
    private var tasks: [Task<Void, Never>] = []

    public init(
        pipeline: IngestPipeline,
        inbox: InboxWatcher,
        pasteboard: PasteboardWatcher,
        didIngest: @escaping @Sendable (AssetRecord, URL?) async -> Void = { _, _ in }
    ) {
        self.pipeline = pipeline
        self.inboxes = [inbox]
        self.pasteboard = pasteboard
        self.didIngest = didIngest
    }

    public init(
        pipeline: IngestPipeline,
        inboxes: [InboxWatcher],
        pasteboard: PasteboardWatcher,
        didIngest: @escaping @Sendable (AssetRecord, URL?) async -> Void = { _, _ in }
    ) {
        self.pipeline = pipeline
        self.inboxes = inboxes
        self.pasteboard = pasteboard
        self.didIngest = didIngest
    }

    deinit {
        for task in tasks {
            task.cancel()
        }
    }

    /// Starts both sources and forwards their events until stopped.
    @discardableResult
    public func start() async throws -> [URL] {
        guard tasks.isEmpty else { return activeInboxes.map(\.directoryURL) }
        guard let primaryInbox = inboxes.first else { return [] }
        try await primaryInbox.start()
        var startedInboxes = [primaryInbox]
        for inbox in inboxes.dropFirst() {
            do {
                try await inbox.start()
                startedInboxes.append(inbox)
            } catch {
                // Additional system capture locations are best-effort. The Reel Inbox remains
                // available when a sandbox or stale preference blocks another directory.
            }
        }
        activeInboxes = startedInboxes
        await pasteboard.start()
        let pipeline = self.pipeline
        for inbox in startedInboxes {
            beginForwarding(inbox, pipeline: pipeline)
        }
        let pasteboardImages = pasteboard.images
        let didIngest = didIngest
        tasks.append(
            Task {
                for await data in pasteboardImages {
                    do {
                        let record = try await pipeline.ingestImageData(data, source: .pasteboard)
                        await didIngest(record, nil)
                    } catch {
                        // IngestPipeline emits the typed failure event.
                    }
                }
            })
        return startedInboxes.map(\.directoryURL)
    }

    public func addInbox(_ inbox: InboxWatcher) async throws {
        guard !activeInboxes.contains(where: { $0.directoryURL == inbox.directoryURL }) else {
            return
        }
        inboxes.removeAll { $0.directoryURL == inbox.directoryURL }
        inboxes.append(inbox)
        guard !tasks.isEmpty else { return }
        try await inbox.start()
        activeInboxes.append(inbox)
        beginForwarding(inbox, pipeline: pipeline)
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
        await pasteboard.stop()
    }

    private func beginForwarding(_ inbox: InboxWatcher, pipeline: IngestPipeline) {
        let inboxEvents = inbox.events
        let didIngest = didIngest
        tasks.append(
            Task {
                for await url in inboxEvents {
                    do {
                        let record = try await pipeline.ingest(url, source: .inbox)
                        await didIngest(record, url)
                    } catch {
                        // IngestPipeline emits the typed failure event.
                    }
                }
            })
    }
}
