import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Appearance preference")
struct AppearancePreferenceTests {
    @Test("Following the system resolves against the supplied colour scheme")
    func systemFollowsColorScheme() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(
            AppearancePreference.system.theme(matching: .dark).palette.surfaceBase
                == Theme.dark.palette.surfaceBase
        )
        #expect(
            AppearancePreference.system.theme(matching: .light).palette.surfaceBase
                == Theme.light.palette.surfaceBase
        )
    }

    @Test("An explicit choice overrides the system colour scheme")
    func explicitChoiceWins() {
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
        #expect(
            AppearancePreference.light.theme(matching: .dark).palette.surfaceBase
                == Theme.light.palette.surfaceBase
        )
        #expect(
            AppearancePreference.dark.theme(matching: .light).palette.surfaceBase
                == Theme.dark.palette.surfaceBase
        )
    }

    @Test("Every preference is selectable and titled")
    func selectableCases() {
        #expect(AppearancePreference.allCases == [.system, .light, .dark])
        #expect(AppearancePreference.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
