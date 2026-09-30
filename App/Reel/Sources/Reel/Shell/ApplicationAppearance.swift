import AppKit
import DesignSystem

/// Keeps AppKit's appearance in step with the appearance clipx was asked for.
///
/// SwiftUI's `preferredColorScheme` only sets the SwiftUI environment. Controls
/// that AppKit draws — menus, popup buttons, the grouped `Form` in Settings —
/// read `NSApplication.effectiveAppearance` instead, which keeps following
/// macOS. Choosing Light while the system is Dark therefore produced a light
/// Settings window with white menu labels on it: SwiftUI drew the background,
/// AppKit drew the text, and the two disagreed about which mode they were in.
enum ApplicationAppearance {
    /// Applies `preference` to the whole application.
    ///
    /// Applied to `NSApp` rather than to one window, because the mismatch is not
    /// specific to Settings — any AppKit-backed control anywhere in the app has
    /// it. `nil` hands control back to macOS, which is what "System" means.
    @MainActor
    static func apply(_ preference: AppearancePreference, to application: NSApplication) {
        application.appearance = nsAppearance(for: preference)
    }

    static func nsAppearance(for preference: AppearancePreference) -> NSAppearance? {
        switch preference {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
