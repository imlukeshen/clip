import Foundation

/// The indexed summary of an event sidecar's alignment quality.
public enum EventAlignmentKind: String, Codable, Sendable {
    case exact
    case estimated
    case unavailable
}
