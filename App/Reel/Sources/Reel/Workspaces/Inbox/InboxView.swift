import AppKit
import DesignSystem
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
                detail: model.libraryRoot.appendingPathComponent("Inbox").path(
                    percentEncoded: false),
                state: model.isWatching ? .ok : .pending
            )
            StatusItem("Clipboard", state: model.isWatching ? .ok : .pending)
            StatusItem(
                "Click track off",
                state: .pending,
                actionTitle: "Grant access",
                action: openAccessibilitySettings
            )
        }
    }

    private func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }
}
