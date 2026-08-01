@preconcurrency import AppKit
import Foundation

/// A key combination decoded from the user's preference domain.
public struct KeyCombo: Sendable, Equatable {
    public var characters: String
    public var modifiers: NSEvent.ModifierFlags

    public init(characters: String, modifiers: NSEvent.ModifierFlags) {
        self.characters = characters
        self.modifiers = modifiers
    }

    /// A display value assembled only from the decoded preference values.
    public var display: String {
        var value = ""
        let orderedModifiers: [(NSEvent.ModifierFlags, UInt32)] = [
            (.control, 0x2303),
            (.option, 0x2325),
            (.shift, 0x21E7),
            (.command, 0x2318),
        ]
        for (modifier, scalarValue) in orderedModifiers where modifiers.contains(modifier) {
            if let scalar = UnicodeScalar(scalarValue) {
                value.append(Character(scalar))
            }
        }
        return value + characters.uppercased()
    }
}
