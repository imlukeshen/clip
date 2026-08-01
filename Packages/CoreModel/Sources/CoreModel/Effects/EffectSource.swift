import Foundation

/// The origin of an effect.
public enum EffectSource: String, Codable, Sendable {
    case manual
    case derivedFromClicks
}
