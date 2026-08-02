@preconcurrency import AVFoundation
import CoreModel
import Foundation

final class ReelVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening: Bool
    var requiredSourceTrackIDs: [NSValue]? {
        sourceTrackID.map { [NSNumber(value: $0)] }
    }
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let itemID: ItemID
    let effects: [Effect]
    let speed: Double
    let preferredTransform: CGAffineTransform
    let background: RGBA
    let sourceTrackID: CMPersistentTrackID?

    init(
        timeRange: CMTimeRange,
        item: TimelineItem,
        preferredTransform: CGAffineTransform,
        background: RGBA,
        sourceTrackID: CMPersistentTrackID?
    ) {
        self.timeRange = timeRange
        self.itemID = item.id
        self.effects = item.effects
        self.speed = item.speed
        self.preferredTransform = preferredTransform
        self.background = background
        self.sourceTrackID = sourceTrackID
        self.containsTweening = !item.effects.isEmpty
    }
}
