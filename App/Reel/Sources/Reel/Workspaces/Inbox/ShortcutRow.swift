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
                        Link("Settings", destination: settingsURL)
                            .font(theme.type.caption.font)
                            .foregroundStyle(theme.palette.accent)
                            .fixedSize()
                    }
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    if assigned.isEmpty {
                        Text("No capture shortcuts assigned")
                            .font(theme.type.caption.font)
                            .foregroundStyle(theme.palette.textTertiary)
                            .lineLimit(1)
                    } else {
                        ForEach(assigned) { item in
                            shortcut(item)
                        }
                    }
                    Button("Re-detect", action: model.refreshShortcuts)
                        .buttonStyle(ReelPlainButtonStyle())
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func shortcut(_ item: ShortcutItem) -> some View {
        HStack(spacing: 5) {
            Text(item.title)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let display = item.display {
                KbdChip(display)
                    .fixedSize()
            }
        }
    }

    private var assigned: [ShortcutItem] {
        model.shortcutRow.items.filter { $0.display != nil }
    }
}
