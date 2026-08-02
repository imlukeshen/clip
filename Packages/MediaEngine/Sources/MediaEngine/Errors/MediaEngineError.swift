import CoreModel
import Foundation

public enum MediaEngineError: Error, Sendable, Equatable {
    case emptyTimeline
    case assetHasNoVideo(AssetID)
    case cannotCreateTrack
    case invalidSourceRange(ItemID)
    case compositionFailed(ItemID, String)
}

extension MediaEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyTimeline: "The timeline has no playable clips."
        case .assetHasNoVideo: "A timeline asset has no video track."
        case .cannotCreateTrack: "The playback tracks could not be created."
        case .invalidSourceRange: "A clip range falls outside its source media."
        case .compositionFailed(_, let reason): reason
        }
    }
}
