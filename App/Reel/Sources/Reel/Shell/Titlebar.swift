import DesignSystem
import ReelAppCore
import SwiftUI

struct Titlebar: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Reel")
                .font(theme.type.title.font)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                TextField("Search library", text: $model.searchQuery)
                    .textFieldStyle(.plain)
            }
            .font(theme.type.label.font)
            .foregroundStyle(theme.palette.textTertiary)
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .frame(maxWidth: 300)
            .background(theme.palette.surfacePanel)
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))

            Spacer()
            Label("Local only", systemImage: "checkmark.circle.fill")
                .font(theme.type.micro.font)
                .foregroundStyle(theme.palette.textTertiary)
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("Local only. Files stay on this Mac")
            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.textTertiary)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(theme.palette.surfaceBase)
    }
}
