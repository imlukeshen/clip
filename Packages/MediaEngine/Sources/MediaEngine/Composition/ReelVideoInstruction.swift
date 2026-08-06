@preconcurrency import AVFoundation
import CoreModel
import Foundation

struct ReelVideoLayer: Sendable {
    let item: TimelineItem
    let preferredTransform: CGAffineTransform
    let sourceTrackID: CMPersistentTrackID
}

final class ReelVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening: Bool
    var requiredSourceTrackIDs: [NSValue]? {
        layers.map { NSNumber(value: $0.sourceTrackID) }
    }
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let layers: [ReelVideoLayer]
    let background: RGBA

    init(
        timeRange: CMTimeRange,
        layers: [ReelVideoLayer],
        background: RGBA
    ) {
        self.timeRange = timeRange
        self.layers = layers
        self.background = background
        containsTweening = layers.contains { layer in
            let item = layer.item
            return !item.effects.isEmpty
                || item.videoFade.fadeIn > .zero
                || item.videoFade.fadeOut > .zero
                || !item.transform.keyframes.isEmpty
                || !item.opacity.keyframes.isEmpty
        }
    }
}
