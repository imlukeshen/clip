import AppKit
import DesignSystem
import Testing

@testable import Reel

@Suite("Application appearance")
struct ApplicationAppearanceTests {
    @Test("An explicit preference is imposed on AppKit, not just on SwiftUI")
    func explicitPreferencesMapToAppKit() {
        // SwiftUI's preferredColorScheme does not reach AppKit-drawn controls.
        // Choosing Light while macOS is Dark left menus drawing white labels on
        // a light Settings window, because each half read a different mode.
        #expect(ApplicationAppearance.nsAppearance(for: .light)?.name == .aqua)
        #expect(ApplicationAppearance.nsAppearance(for: .dark)?.name == .darkAqua)
    }

    @Test("Following the system means imposing nothing")
    func systemPreferenceDefersToMacOS() {
        // Pinning aqua here would freeze the app in whatever mode macOS happened
        // to be in at launch, and stop it following a later change.
        #expect(ApplicationAppearance.nsAppearance(for: .system) == nil)
    }

    @Test("Every preference is mapped")
    func everyPreferenceIsCovered() {
        for preference in AppearancePreference.allCases {
            let appearance = ApplicationAppearance.nsAppearance(for: preference)
            #expect((preference == .system) == (appearance == nil))
        }
    }
}
