import CoreModel
import Foundation

/// A durable library mutation observed by app state.
public enum LibraryChange: Sendable, Equatable {
    case assetInserted(AssetID)
    case assetDeleted(AssetID)
    case projectSaved(ProjectID)
    case indexRebuilt
}
