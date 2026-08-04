import AIKit
import DesignSystem
import ReelAppCore
import SwiftUI

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    private var commands: [CommandDefinition] {
        CommandRegistry.all.filter { command in
            model.commandQuery.isEmpty
                || command.title.localizedCaseInsensitiveContains(model.commandQuery)
                || command.id.rawValue.localizedCaseInsensitiveContains(model.commandQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                TextField("Type a command…", text: $model.commandQuery)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("command-palette-search")
                HStack(spacing: 2) {
                    Image(systemName: "command")
                    Text("K")
                }
                .font(theme.type.numeric.font)
                .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(14)
            Divider().overlay(theme.palette.line)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(commands) { command in
                        Button {
                            model.runPaletteCommand(command.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: command.category)).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.title)
                                    Text(command.id.rawValue)
                                        .font(theme.type.numeric.font)
                                        .foregroundStyle(theme.palette.textTertiary)
                                }
                                Spacer()
                                Text(command.category.rawValue.capitalized)
                                    .font(theme.type.caption.font)
                                    .foregroundStyle(theme.palette.textTertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ReelPlainButtonStyle())
                        .accessibilityIdentifier("command-\(command.id.rawValue)")
                    }
                }
                .padding(6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-palette")
        .frame(width: 620, height: 480)
        .background {
            ZStack {
                theme.palette.surfaceBase
                OutsideClickMonitor(isActive: model.isCommandPalettePresented) {
                    model.isCommandPalettePresented = false
                }
            }
        }
        .onDisappear { model.commandQuery = "" }
    }

    private func icon(for category: CommandCategory) -> String {
        switch category {
        case .asset: "photo.on.rectangle"
        case .clip: "film"
        case .effect: "sparkles"
        case .audio: "waveform"
        case .timeline: "timeline.selection"
        case .image: "photo.badge.wand.fill"
        case .pdf: "doc.richtext"
        case .text: "curlybraces"
        case .file: "doc"
        case .view: "rectangle.3.group"
        case .app: "command"
        }
    }
}
