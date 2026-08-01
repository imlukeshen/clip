import Foundation

/// A stable effect category used by renderers and inspectors.
public enum EffectKind: Sendable, Equatable {
    case zoom
    case crop
    case background
    case blur
    case cursor
    case text
    case unknown(String)
}
