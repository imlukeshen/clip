import Foundation

/// Why Reel cannot truthfully display the user's screenshot shortcuts.
public enum UnavailableReason: Sendable, Equatable {
    case sandboxed
    case missingDomain
}

/// The complete outcome of reading the system screenshot-shortcut preferences.
public enum ShortcutReadResult: Sendable, Equatable {
    /// A present key with a nil value is an explicitly disabled or unavailable action.
    case available([ScreenshotAction: KeyCombo?])
    case unavailable(reason: UnavailableReason)
}
