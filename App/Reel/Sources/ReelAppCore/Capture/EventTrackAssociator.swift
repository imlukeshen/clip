import CaptureKit
import CoreGraphics
import CoreModel
import Foundation
import LibraryStore

/// Owns optional click capture and associates its rolling buffer with imported videos.
public actor EventTrackAssociator {
    private let library: LibraryStore
    private let recorder: EventTapRecorder
    private let detector: CaptureWindowDetector
    private var isActive = false

    public init(
        library: LibraryStore,
        bufferDuration: Duration = .seconds(300)
    ) {
        self.library = library
        self.recorder = EventTapRecorder(bufferDuration: bufferDuration)
        self.detector = CaptureWindowDetector()
    }

    public func start() async -> ClickTrackingState {
        await detector.start()
        guard EventTapRecorder.isAuthorized() else {
            isActive = false
            return state
        }
        do {
            try await recorder.start()
            isActive = true
            return state
        } catch {
            isActive = false
            return .disabled(reason: error.localizedDescription)
        }
    }

    public func stop() async {
        await recorder.stop()
        await detector.stop()
        isActive = false
    }

    public var state: ClickTrackingState {
        if isActive {
            return .enabled(bufferDurationSeconds: 300)
        }
        return .disabled(
            reason:
                "Accessibility access is off. Reel still imports normally, but auto-zoom is unavailable."
        )
    }

    @discardableResult
    public func associate(_ record: AssetRecord, sourceURL: URL?) async -> AssetRecord {
        guard record.kind == .video,
            let duration = record.duration,
            isActive
        else { return record }
        if record.eventTrackPath != nil { return record }

        let dates = fileDates(at: sourceURL)
        let events = await recorder.slice(from: 0, to: .max)
        let windows = await detector.recentWindows()
        let track = EventTrackAligner().align(
            assetDuration: duration,
            fileCreated: dates.created ?? record.createdAt,
            fileModified: dates.modified ?? record.createdAt.addingTimeInterval(duration.seconds),
            windows: windows,
            events: events,
            displayBounds: CGDisplayBounds(CGMainDisplayID()),
            assetID: record.id
        )
        return (try? await library.storeEventTrack(track)) ?? record
    }

    private func fileDates(at url: URL?) -> (created: Date?, modified: Date?) {
        guard let url else { return (nil, nil) }
        let values = try? url.resourceValues(forKeys: [
            .creationDateKey, .contentModificationDateKey,
        ])
        return (values?.creationDate, values?.contentModificationDate)
    }
}
