@preconcurrency import AVFoundation
import CoreModel
import Foundation

public struct BuiltComposition {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVAudioMix
    public let itemsByTrackID: [CMPersistentTrackID: ItemID]

    public init(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVAudioMix,
        itemsByTrackID: [CMPersistentTrackID: ItemID]
    ) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.itemsByTrackID = itemsByTrackID
    }
}
