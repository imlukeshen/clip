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
                title: "Inbox",
                subtitle:
                    "Capture with the screenshot shortcuts you already have set. Files land here on their own."
            )
            WorkspaceDropZone(model: model, workspace: .inbox)
            WatcherStatusStrip(model: model)
                .padding(.top, 16)
            ShortcutRow(model: model)
                .padding(.top, 12)
            SectionLabel("Arrived")
                .padding(.top, 28)
                .padding(.bottom, 11)
            AssetGrid(model: model, assets: model.visibleAssets)
        }
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
