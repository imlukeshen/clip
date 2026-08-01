import Foundation

/// The actor responsible for a graph patch.
public enum Origin: Codable, Sendable, Equatable {
    case user
    case assistant(turnID: String)
    case automation(rule: String)
}
