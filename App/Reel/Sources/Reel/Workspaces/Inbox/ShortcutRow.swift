import DesignSystem
import ReelAppCore
import SwiftUI

struct ShortcutRow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            if let guidance = model.shortcutRow.guidance {
                Text(guidance)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                if let settingsURL = model.shortcutRow.settingsURL {
                    Link("Open settings", destination: settingsURL)
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.accent)
                }
            } else {
                ForEach(model.shortcutRow.items) { item in
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(theme.type.caption.font)
                            .foregroundStyle(theme.palette.textTertiary)
                        if let display = item.display {
                            KbdChip(display)
                        } else {
                            KbdChip("Disabled", state: .disabled)
                        }
                    }
                }
                Button("Re-detect") {
                    model.refreshShortcuts()
                }
                .buttonStyle(.plain)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
