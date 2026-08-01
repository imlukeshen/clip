import Foundation

/// Broad media kinds used to filter the library.
public enum AssetKind: String, Codable, Sendable, CaseIterable {
    case video
    case image
    case audio
    case document
}
