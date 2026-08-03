import DesignSystem
import ReelAppCore
import SwiftUI

struct ShortcutRow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let guidance = model.shortcutRow.guidance {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(guidance)
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textTertiary)
                        .lineLimit(2)
                    if let settingsURL = model.shortcutRow.settingsURL {
                        Link("Open settings", destination: settingsURL)
                            .font(theme.type.caption.font)
                            .foregroundStyle(theme.palette.accent)
                    }
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(model.shortcutRow.items) { item in
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(theme.type.caption.font)
                                .foregroundStyle(theme.palette.textTertiary)
                                .lineLimit(2)
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
                    .buttonStyle(ReelPlainButtonStyle())
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
