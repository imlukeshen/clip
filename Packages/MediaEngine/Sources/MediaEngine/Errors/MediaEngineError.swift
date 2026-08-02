import CoreModel
import Foundation

public enum MediaEngineError: Error, Sendable, Equatable {
    case emptyTimeline
    case assetHasNoVideo(AssetID)
    case cannotCreateTrack
    case invalidSourceRange(ItemID)
    case compositionFailed(ItemID, String)
    case invalidExportPreset(String)
    case cannotCreateOutput
    case exportFailed(String)
    case cancelled
}

extension MediaEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyTimeline: "The timeline has no playable clips."
        case .assetHasNoVideo: "A timeline asset has no video track."
        case .cannotCreateTrack: "The playback tracks could not be created."
        case .invalidSourceRange: "A clip range falls outside its source media."
        case .compositionFailed(_, let reason): reason
        case .invalidExportPreset(let reason): reason
        case .cannotCreateOutput: "The export destination could not be prepared."
        case .exportFailed(let reason): reason
        case .cancelled: "The export was cancelled."
        }
    }
}
