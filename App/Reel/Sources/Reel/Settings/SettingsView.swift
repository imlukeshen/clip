import DesignSystem
import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    let libraryRoot: URL

    var body: some View {
        SettingsContent(libraryRoot: libraryRoot)
            .environment(\.theme, colorScheme == .dark ? Theme.dark : Theme.light)
            .frame(width: 460, height: 220)
    }
}

private struct SettingsContent: View {
    @Environment(\.theme) private var theme
    let libraryRoot: URL

    var body: some View {
        Form {
            LabeledContent("Library") {
                Text(libraryRoot.path(percentEncoded: false))
                    .font(theme.type.numeric.font)
                    .textSelection(.enabled)
            }
            LabeledContent("Privacy") {
                Text("Local only")
            }
        }
        .formStyle(.grouped)
        .font(theme.type.body.font)
        .foregroundStyle(theme.palette.textPrimary)
        .background(theme.palette.surfaceBase)
    }
}
