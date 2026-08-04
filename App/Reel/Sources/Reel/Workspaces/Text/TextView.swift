import CoreModel
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct TextView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        if let editor = model.textEditor {
            TextEditorWorkspace(model: model, editor: editor)
        } else {
            library
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.isSearching {
                WorkspaceDropZone(model: model, workspace: .text)
                HStack(spacing: theme.metrics.spacing.sm) {
                    Button("New scratch", action: model.createScratchTextEditor)
                        .buttonStyle(ReelBorderedButtonStyle())
                        .accessibilityIdentifier("text-new-scratch")
                    Button("Open editor") {
                        guard let selectedTextAsset else { return }
                        model.openTextEditor(for: selectedTextAsset.id)
                    }
                    .buttonStyle(ReelBorderedButtonStyle())
                    .disabled(selectedTextAsset == nil)
                }
                .padding(.top, theme.metrics.spacing.md)

                if !model.scratchBuffers.isEmpty {
                    VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
                        SectionLabel("Scratch")
                        ForEach(model.scratchBuffers) { buffer in
                            Button {
                                model.openScratchTextEditor(buffer.id)
                            } label: {
                                HStack(spacing: theme.metrics.spacing.md) {
                                    Image(systemName: "note.text")
                                        .foregroundStyle(theme.palette.textTertiary)
                                    Text(buffer.name)
                                        .font(theme.type.label.font)
                                        .foregroundStyle(theme.palette.textPrimary)
                                    Spacer()
                                    Text(buffer.modifiedAt, style: .relative)
                                        .font(theme.type.caption.font)
                                        .foregroundStyle(theme.palette.textTertiary)
                                }
                                .padding(.horizontal, theme.metrics.spacing.lg)
                                .frame(height: 38)
                                .background(theme.palette.surfacePanel)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: theme.metrics.radius.control,
                                        style: .continuous
                                    )
                                )
                            }
                            .buttonStyle(ReelPlainButtonStyle())
                            .accessibilityIdentifier("scratch-buffer-\(buffer.id.rawValue)")
                        }
                    }
                    .padding(.top, theme.metrics.spacing.xl)
                }
            }
            AssetGrid(
                model: model,
                assets: model.visibleAssets.filter { $0.kind == .text }
            )
            .padding(.top, theme.metrics.spacing.xl)
        }
    }

    private var selectedTextAsset: AssetRecord? {
        guard let selectedAssetID = model.selectedAssetID else { return nil }
        return model.assets.first {
            $0.id.rawValue == selectedAssetID && $0.kind == .text
        }
    }
}
