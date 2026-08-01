import Foundation

/// Mouse buttons captured in an event sidecar.
public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case other
}
