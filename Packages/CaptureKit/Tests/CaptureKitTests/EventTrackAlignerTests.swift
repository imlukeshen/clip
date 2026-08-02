import CoreGraphics
import CoreModel
import Foundation
import Testing

@testable import CaptureKit

@Test func exactAlignmentUsesTheMatchedCaptureWindow() {
    let assetID = AssetID(rawValue: "asset-exact")
    let baseHostTime = HostClock.ticks(for: 50)
    let startedAt = Date(timeIntervalSince1970: 2_000_000)
    let endedAt = startedAt.addingTimeInterval(4)
    let window = CaptureWindow(
        start: baseHostTime,
        end: baseHostTime + HostClock.ticks(for: 4),
        startedAt: startedAt,
        endedAt: endedAt
    )
    let click = RawEvent(
        machHostTime: baseHostTime + HostClock.ticks(for: 1.2),
        wallTime: startedAt.addingTimeInterval(1.2),
        location: CGPoint(x: 320, y: 180),
        kind: .leftMouseDown,
        clickCount: 1
    )

    let track = EventTrackAligner().align(
        assetDuration: RationalTime(seconds: 4),
        fileCreated: startedAt,
        fileModified: endedAt.addingTimeInterval(0.4),
        windows: [window],
        events: [click],
        displayBounds: CGRect(x: 0, y: 0, width: 640, height: 360),
        assetID: assetID
    )

    guard case .exact = track.alignment else {
        Issue.record("Expected exact alignment")
        return
    }
    #expect(track.assetID == assetID)
    #expect(track.clicks.count == 1)
    #expect(abs(track.clicks[0].time.seconds - 1.2) < 0.002)
    #expect(track.clicks[0].point == NormalizedPoint(x: 0.5, y: 0.5))
}

@Test func estimatedAlignmentUsesFileDatesAndReportsConfidence() {
    let created = Date(timeIntervalSince1970: 3_000_000)
    let event = RawEvent(
        machHostTime: 10,
        wallTime: created.addingTimeInterval(3),
        location: CGPoint(x: 25, y: 75),
        kind: .rightMouseDown,
        clickCount: 2
    )

    let track = EventTrackAligner().align(
        assetDuration: RationalTime(seconds: 10),
        fileCreated: created,
        fileModified: created.addingTimeInterval(10.5),
        windows: [],
        events: [event],
        displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
        assetID: AssetID(rawValue: "asset-estimated")
    )

    guard case .estimated(_, let confidence) = track.alignment else {
        Issue.record("Expected estimated alignment")
        return
    }
    #expect(abs(confidence - 0.75) < 0.001)
    #expect(track.clicks.map(\.time) == [RationalTime(seconds: 3)])
    #expect(track.clicks.map(\.button) == [.right])
    #expect(track.clicks.map(\.clickCount) == [2])
}

@Test func alignmentRejectsAPathThatMostlyLeavesTheDisplay() {
    let startedAt = Date(timeIntervalSince1970: 4_000_000)
    let base = HostClock.ticks(for: 100)
    let window = CaptureWindow(
        start: base,
        end: base + HostClock.ticks(for: 5),
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(5)
    )
    let events = (0..<5).map { index in
        RawEvent(
            machHostTime: base + HostClock.ticks(for: Double(index)),
            wallTime: startedAt.addingTimeInterval(Double(index)),
            location: index < 2 ? CGPoint(x: -10, y: 10) : CGPoint(x: 10, y: 10),
            kind: .mouseMoved
        )
    }

    let track = EventTrackAligner().align(
        assetDuration: RationalTime(seconds: 5),
        fileCreated: startedAt,
        fileModified: startedAt.addingTimeInterval(5),
        windows: [window],
        events: events,
        displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
    )

    #expect(
        track.alignment == .unavailable(reason: "cursor left the recorded display for too long"))
    #expect(track.samples.isEmpty)
}

@Test func processMatchingIsExactAndCaseInsensitive() {
    #expect(CaptureWindowDetector.containsScreenCaptureProcess(names: ["Finder", "screencapture"]))
    #expect(CaptureWindowDetector.containsScreenCaptureProcess(names: ["SCREENCAPTURE"]))
    #expect(!CaptureWindowDetector.containsScreenCaptureProcess(names: ["ScreenCaptureKitDemo"]))
}
