import Foundation
import Testing

@testable import MediaEngine

@Suite("Effect compositor cancellation")
struct EffectCompositorTests {
    @Test("Cancelling pending requests does not mute the ones that follow")
    func cancellationDoesNotPersist() {
        let compositor = EffectCompositor()
        let inFlight = compositor.currentGeneration

        compositor.cancelAllPendingVideoCompositionRequests()

        // Work already queued is retired.
        #expect(!compositor.isCurrent(inFlight))
        // Anything issued afterwards must still render. AVFoundation cancels on
        // every seek, pause and rate change, so treating cancellation as sticky
        // left the player waiting forever for a frame and its clock frozen.
        let reissued = compositor.currentGeneration
        #expect(compositor.isCurrent(reissued))
    }

    @Test("Repeated cancellation keeps issuing usable generations")
    func repeatedCancellationStaysUsable() {
        let compositor = EffectCompositor()
        for _ in 0..<50 {
            compositor.cancelAllPendingVideoCompositionRequests()
            #expect(compositor.isCurrent(compositor.currentGeneration))
        }
    }
}
