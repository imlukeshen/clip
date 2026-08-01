import Foundation

/// A mutable media track in the project graph.
public enum TrackKind: String, Codable, Sendable {
    case video
    case audio
}
