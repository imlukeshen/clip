@preconcurrency import AppKit
import Foundation

private enum ShortcutPreferenceAccess: Sendable {
    case direct
    case sandboxed
}

/// Reads public preference data for the user's configured screenshot shortcuts.
public struct ShortcutReader: Sendable {
    private static let preferenceDomain = "com.apple.symbolichotkeys"
    private static let shortcutKey = "AppleSymbolicHotKeys"

    private let access: ShortcutPreferenceAccess

    public init() {
        self.access =
            ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
            ? .direct : .sandboxed
    }

    /// Creates a reader for an explicitly known build channel.
    public init(sandboxed: Bool) {
        self.access = sandboxed ? .sandboxed : .direct
    }

    /// Reads the preference domain or returns a reason the UI must use neutral guidance.
    public func read() -> ShortcutReadResult {
        guard access == .direct else {
            return .unavailable(reason: .sandboxed)
        }
        guard
            let domain = UserDefaults.standard.persistentDomain(
                forName: Self.preferenceDomain
            ),
            let data = try? PropertyListSerialization.data(
                fromPropertyList: domain,
                format: .binary,
                options: 0
            )
        else {
            return .unavailable(reason: .missingDomain)
        }
        return (try? Self.decode(propertyListData: data))
            ?? .unavailable(reason: .missingDomain)
    }

    /// Decodes plist data. Exposed so fixtures can exercise the public file format.
    public static func decode(propertyListData data: Data) throws -> ShortcutReadResult {
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard
            let root = propertyList as? [String: Any],
            let entries = root[shortcutKey] as? [String: Any]
        else {
            return .unavailable(reason: .missingDomain)
        }

        var result: [ScreenshotAction: KeyCombo?] = [:]
        for action in ScreenshotAction.allCases {
            let combo = decodeAction(entries[String(action.rawValue)])
            result.updateValue(combo, forKey: action)
        }
        return .available(result)
    }

    private static func decodeAction(_ rawEntry: Any?) -> KeyCombo? {
        guard
            let entry = rawEntry as? [String: Any],
            (entry["enabled"] as? NSNumber)?.boolValue == true,
            let value = entry["value"] as? [String: Any],
            let rawParameters = value["parameters"] as? [Any],
            rawParameters.count >= 3,
            let characterCode = rawParameters[0] as? NSNumber,
            let virtualKeyCode = rawParameters[1] as? NSNumber,
            let modifierMask = rawParameters[2] as? NSNumber,
            let characters = characters(
                characterCode: characterCode.intValue,
                virtualKeyCode: virtualKeyCode.intValue
            )
        else {
            return nil
        }

        return KeyCombo(
            characters: characters,
            modifiers: modifiers(mask: modifierMask.intValue)
        )
    }

    private static func modifiers(mask: Int) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if mask & (1 << 17) != 0 { modifiers.insert(.shift) }
        if mask & (1 << 18) != 0 { modifiers.insert(.control) }
        if mask & (1 << 19) != 0 { modifiers.insert(.option) }
        if mask & (1 << 20) != 0 { modifiers.insert(.command) }
        return modifiers
    }

    private static func characters(characterCode: Int, virtualKeyCode: Int) -> String? {
        if characterCode != 65_535,
            let scalar = UnicodeScalar(characterCode),
            !CharacterSet.controlCharacters.contains(scalar)
        {
            return String(Character(scalar)).uppercased()
        }

        let virtualKeys: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
            17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9",
            26: "7", 28: "8", 29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
        ]
        return virtualKeys[virtualKeyCode]
    }
}
