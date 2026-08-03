import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct InboxView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(
                title: model.isSearching ? "Search" : model.currentFolderName,
                subtitle: model.isSearching
                    ? "\(model.searchResultDescription) matching “\(model.searchQuery)”."
                    : "Capture with the screenshot shortcuts you already have set. Files land here on their own."
            )
            if model.isSearching {
                searchResults
            } else {
                WorkspaceDropZone(model: model, workspace: .inbox)
                WatcherStatusStrip(model: model)
                    .padding(.top, 16)
                ShortcutRow(model: model)
                    .padding(.top, 12)
                SectionLabel("Media")
                    .padding(.top, 28)
                    .padding(.bottom, 11)
                AssetGrid(model: model, assets: model.visibleAssets)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if !model.matchingFolders.isEmpty {
            SectionLabel("Folders")
                .padding(.bottom, 9)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.matchingFolders) { folder in
                        Button {
                            model.selectFolder(folder.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(theme.palette.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.name)
                                        .font(theme.type.label.font)
                                    Text(folder.id)
                                        .font(theme.type.micro.font)
                                        .foregroundStyle(theme.palette.textTertiary)
                                        .lineLimit(1)
                                }
                                if folder.assetCount > 0 {
                                    Text("\(folder.assetCount)")
                                        .font(theme.type.numeric.font)
                                        .foregroundStyle(theme.palette.textTertiary)
                                }
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 42)
                            .background(theme.palette.surfacePanel)
                            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
                            .overlay {
                                RoundedRectangle(cornerRadius: theme.metrics.radius.control)
                                    .strokeBorder(
                                        theme.palette.line,
                                        lineWidth: theme.metrics.hairline
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 24)
        }
        SectionLabel("Media")
            .padding(.bottom, 11)
        AssetGrid(model: model, assets: model.visibleAssets)
    }
}

private struct WatcherStatusStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        StatusStrip {
            StatusItem(
                model.isWatching ? "Watching" : "Opening library",
                detail: LibraryLayout.inbox(in: model.libraryRoot).path(
                    percentEncoded: false),
                state: model.isWatching ? .ok : .pending
            )
            StatusItem("Clipboard", state: model.isWatching ? .ok : .pending)
            clickTrackingStatus
        }
    }

    @ViewBuilder private var clickTrackingStatus: some View {
        switch model.clickTrackingState {
        case .checking:
            StatusItem("Checking click track", state: .pending)
        case .enabled(let seconds):
            StatusItem("Click track", detail: "\(seconds)s buffer", state: .ok)
        case .disabled(let reason):
            StatusItem(
                "Click track off",
                detail: reason,
                state: .pending,
                actionTitle: "Grant access",
                action: model.requestClickTrackingAccess
            )
        }
    }

}
