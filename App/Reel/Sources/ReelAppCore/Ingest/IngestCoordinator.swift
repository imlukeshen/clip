import CaptureKit
import Foundation
import LibraryStore

/// Connects capture-source streams to the single ingest pipeline.
public actor IngestCoordinator {
    private let pipeline: IngestPipeline
    private let inbox: InboxWatcher
    private let pasteboard: PasteboardWatcher
    private let didIngest: @Sendable (AssetRecord, URL?) async -> Void
    private var tasks: [Task<Void, Never>] = []

    public init(
        pipeline: IngestPipeline,
        inbox: InboxWatcher,
        pasteboard: PasteboardWatcher,
        didIngest: @escaping @Sendable (AssetRecord, URL?) async -> Void = { _, _ in }
    ) {
        self.pipeline = pipeline
        self.inbox = inbox
        self.pasteboard = pasteboard
        self.didIngest = didIngest
    }

    deinit {
        for task in tasks {
            task.cancel()
        }
    }

    /// Starts both sources and forwards their events until stopped.
    public func start() async throws {
        guard tasks.isEmpty else { return }
        try await inbox.start()
        await pasteboard.start()
        let pipeline = self.pipeline
        let inboxEvents = inbox.events
        let pasteboardImages = pasteboard.images
        let didIngest = didIngest
        tasks = [
            Task {
                for await url in inboxEvents {
                    do {
                        let record = try await pipeline.ingest(url, source: .inbox)
                        await didIngest(record, url)
                    } catch {
                        // IngestPipeline emits the typed failure event.
                    }
                }
            },
            Task {
                for await data in pasteboardImages {
                    do {
                        let record = try await pipeline.ingestImageData(data, source: .pasteboard)
                        await didIngest(record, nil)
                    } catch {
                        // IngestPipeline emits the typed failure event.
                    }
                }
            },
        ]
    }

    /// Stops source polling and event forwarding.
    public func stop() async {
        for task in tasks {
            task.cancel()
        }
        tasks = []
        await inbox.stop()
        await pasteboard.stop()
    }
}
