import AppKit
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct InboxView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isSearching {
                searchResults
            } else {
                WorkspaceDropZone(model: model, workspace: .inbox)
                WatcherStatusStrip(model: model)
                    .padding(.top, 10)
                ShortcutRow(model: model)
                    .padding(.top, 10)
                AssetGrid(model: model, assets: model.visibleAssets)
                    .padding(.top, 24)
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
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: theme.metrics.radius.control,
                                    style: .continuous
                                )
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: theme.metrics.radius.control,
                                    style: .continuous
                                )
                                .strokeBorder(
                                    theme.palette.line,
                                    lineWidth: theme.metrics.hairline
                                )
                            }
                        }
                        .buttonStyle(ReelPlainButtonStyle())
                    }
                }
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 20)
        }
        AssetGrid(model: model, assets: model.visibleAssets)
    }
}

private struct WatcherStatusStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        StatusStrip {
            captureStatus
            historyStatus
            clickTrackingStatus
        }
    }

    @ViewBuilder private var captureStatus: some View {
        if !model.isWatching {
            StatusItem("Opening library", state: .pending)
        } else if model.isCaptureDirectoryWatched {
            StatusItem(
                "Watching",
                detail: model.captureDirectory.lastPathComponent,
                state: .ok
            )
        } else {
            StatusItem(
                "Capture access",
                state: .pending,
                actionTitle: "Choose folder",
                action: chooseCaptureFolder
            )
        }
    }

    /// Captures land here rather than in the library, so the count is the honest
    /// thing to show: it says where they went and that they are temporary.
    private var historyStatus: some View {
        StatusItem(
            "History",
            detail: model.captureHistory.isEmpty
                ? "Empty" : "\(model.captureHistory.count)",
            state: .ok,
            actionTitle: "Open",
            action: { AppCommandRouter.run("capture.history", in: model) }
        )
    }

    private func chooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = model.captureDirectory
        panel.message = "Choose the folder macOS uses for screenshots and screen recordings."
        panel.prompt = "Watch Folder"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.grantCaptureDirectoryAccess(url)
        }
    }

    @ViewBuilder private var clickTrackingStatus: some View {
        switch model.clickTrackingState {
        case .checking:
            StatusItem("Click tracking", state: .pending)
        case .enabled(let seconds):
            StatusItem("Click tracking", detail: "\(seconds)s", state: .ok)
        case .disabled:
            StatusItem(
                "Click tracking",
                state: .pending,
                actionTitle: "Enable",
                action: model.requestClickTrackingAccess
            )
        }
    }

}
