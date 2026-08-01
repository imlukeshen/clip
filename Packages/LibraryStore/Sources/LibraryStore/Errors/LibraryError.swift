import CoreModel
import Foundation

/// Stable failures surfaced by the library boundary.
public enum LibraryError: Error, Sendable, Equatable {
    case assetNotFound(AssetID)
    case duplicateAsset(AssetID)
    case projectNotFound(ProjectID)
    case assetFileMissing(String)
    case invalidRelativePath(String)
    case duplicateContentHash(String)
    case corruptMetadata(String)
    case bookmarkNotFound(String)
    case bookmarkCreationFailed(String)
    case bookmarkResolutionFailed(String)
    case staleBookmark(String)
    case securityScopeDenied(String)
    case fileOperationFailed(String)
    case databaseOperationFailed(String)
}
