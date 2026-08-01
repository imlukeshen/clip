import Foundation

/// Interpolation curves supported by time-varying effects.
public enum Easing: String, Codable, Sendable {
    case linear
    case smoothstep
    case easeInOut
}
