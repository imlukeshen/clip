import Testing

@testable import ReelAppCore

@Suite("Timeline clip hit testing")
struct TimelineClipHitTesterTests {
    @Test("Dense clips keep their complete area available for moving")
    func denseClip() {
        #expect(TimelineClipHitTester.intent(localX: 0, clipWidth: 12) == .move)
        #expect(TimelineClipHitTester.intent(localX: 6, clipWidth: 12) == .move)
        #expect(TimelineClipHitTester.intent(localX: 12, clipWidth: 12) == .move)
    }

    @Test("Wider clips expose proportional trim handles and a guaranteed move center")
    func trimHandles() {
        #expect(TimelineClipHitTester.intent(localX: 3, clipWidth: 20) == .leadingTrim)
        #expect(TimelineClipHitTester.intent(localX: 4.1, clipWidth: 20) == .move)
        #expect(TimelineClipHitTester.intent(localX: 15.9, clipWidth: 20) == .move)
        #expect(TimelineClipHitTester.intent(localX: 17, clipWidth: 20) == .trailingTrim)
        #expect(TimelineClipHitTester.intent(localX: 50, clipWidth: 100) == .move)
    }
}
