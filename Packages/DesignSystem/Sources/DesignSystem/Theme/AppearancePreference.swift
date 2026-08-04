import SwiftUI

/// The appearance a person has chosen for Clip, independent of the macOS setting.
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The scheme to impose on Clip's windows, or `nil` to follow macOS.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Resolves the token set, consulting `systemColorScheme` only while following macOS.
    public func theme(matching systemColorScheme: ColorScheme) -> Theme {
        switch self {
        case .system: systemColorScheme == .dark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }
}
