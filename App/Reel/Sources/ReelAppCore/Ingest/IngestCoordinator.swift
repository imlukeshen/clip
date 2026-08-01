import CaptureKit
import Foundation

/// Connects capture-source streams to the single ingest pipeline.
public actor IngestCoordinator {
    private let pipeline: IngestPipeline
    private let inbox: InboxWatcher
    private let pasteboard: PasteboardWatcher
    private var tasks: [Task<Void, Never>] = []

    public init(
        pipeline: IngestPipeline,
        inbox: InboxWatcher,
        pasteboard: PasteboardWatcher
    ) {
        self.pipeline = pipeline
        self.inbox = inbox
        self.pasteboard = pasteboard
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
        tasks = [
            Task {
                for await url in inboxEvents {
                    do {
                        _ = try await pipeline.ingest(url, source: .inbox)
                    } catch {
                        // IngestPipeline emits the typed failure event.
                    }
                }
            },
            Task {
                for await data in pasteboardImages {
                    do {
                        _ = try await pipeline.ingestImageData(data, source: .pasteboard)
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
