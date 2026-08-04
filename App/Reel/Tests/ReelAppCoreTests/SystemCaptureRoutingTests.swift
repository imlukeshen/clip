import CaptureKit
import Testing

@testable import ReelAppCore

@Suite("System capture routing")
struct SystemCaptureRoutingTests {
    @Test("Screenshots always enter the app clipboard while Clip is running")
    func screenshotsUseHistory() {
        for destination in CaptureDestination.allCases {
            #expect(
                SystemCaptureRouting.route(
                    kind: .image,
                    destination: destination,
                    hasTimelineEditor: false,
                    hasBlockingEditor: false
                ) == .history
            )
        }
    }

    @Test("A new recording opens a timeline by default")
    func recordingsOpenTimeline() {
        #expect(
            SystemCaptureRouting.route(
                kind: .video,
                destination: .timeline,
                hasTimelineEditor: false,
                hasBlockingEditor: false
            ) == .timeline
        )
    }

    @Test("A recording appends to an open timeline regardless of the fallback preference")
    func recordingsAppendToTimeline() {
        for destination in CaptureDestination.allCases {
            #expect(
                SystemCaptureRouting.route(
                    kind: .video,
                    destination: destination,
                    hasTimelineEditor: true,
                    hasBlockingEditor: false
                ) == .timeline
            )
        }
    }

    @Test("An occupied non-video editor stages recordings instead of discarding them")
    func blockedTimelineUsesHistory() {
        #expect(
            SystemCaptureRouting.route(
                kind: .video,
                destination: .timeline,
                hasTimelineEditor: false,
                hasBlockingEditor: true
            ) == .history
        )
        #expect(
            SystemCaptureRouting.route(
                kind: .video,
                destination: .clipboard,
                hasTimelineEditor: false,
                hasBlockingEditor: true
            ) == .history
        )
        #expect(
            SystemCaptureRouting.route(
                kind: .video,
                destination: .file,
                hasTimelineEditor: false,
                hasBlockingEditor: true
            ) == .ignore
        )
    }
}
