import AppKit
import Combine
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct MainWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppModel

    private var theme: Theme { model.appearance.theme(matching: colorScheme) }

    var body: some View {
        content
            .environment(\.theme, theme)
            // Keeps stock controls (sliders, toggles, pickers) on Clip's neutral
            // accent instead of the system blue.
            .tint(theme.palette.accent)
            .preferredColorScheme(model.appearance.colorScheme)
            .alert(
                "Move to Trash?",
                isPresented: Binding(
                    get: { model.pendingTrashConfirmation != nil },
                    set: { if !$0 { model.cancelTrash() } }
                )
            ) {
                Button("Cancel", role: .cancel, action: model.cancelTrash)
                    .keyboardShortcut(.defaultAction)
                Button("Move to Trash", role: .destructive, action: model.confirmTrash)
            } message: {
                Text(trashWarning)
            }
            .sheet(item: migrationBinding) { plan in
                MigrationPlanView(
                    plan: plan,
                    confirm: model.confirmMigration,
                    cancel: model.deferMigration
                )
            }
            .sheet(isPresented: $model.isCommandPalettePresented) {
                CommandPaletteView(model: model)
                    .environment(\.theme, theme)
                    .tint(theme.palette.accent)
            }
            .sheet(isPresented: $model.isCaptureHistoryPresented) {
                CaptureHistoryView(model: model)
                    .environment(\.theme, theme)
                    .tint(theme.palette.accent)
            }
    }

    private var migrationBinding: Binding<LibraryMigrationPlan?> {
        Binding(
            get: { model.pendingMigrationPlan },
            set: { if $0 == nil { model.deferMigration() } }
        )
    }

    private var trashWarning: String {
        guard let confirmation = model.pendingTrashConfirmation else { return "" }
        let projects = confirmation.projectNames.joined(separator: ", ")
        let count = confirmation.assetIDs.count
        return
            "\(count == 1 ? "This file is" : "These \(count) files are") used by: \(projects). The projects will show missing media until you undo or locate the files."
    }

    private var content: some View {
        ThemedMainWindow(model: model)
            .task { await model.start() }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            ) {
                _ in model.refreshSystemAccess()
            }
    }
}

private struct MigrationPlanView: View {
    let plan: LibraryMigrationPlan
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Upgrade your Clip library")
                .font(.title2.weight(.semibold))
            Text(
                "Clip will give \(plan.records.count) assets readable filenames, move them into Media/Inbox, and hide generated previews in .reel. Asset IDs and projects will not change."
            )
            List(plan.moves.prefix(40), id: \.sourceRelativePath) { move in
                VStack(alignment: .leading, spacing: 3) {
                    Text(move.sourceRelativePath).font(.caption.monospaced())
                    Text("→ \(move.destinationRelativePath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 260)
            if plan.moves.count > 40 {
                Text("Plus \(plan.moves.count - 40) more moves")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("You can revert this migration from Settings for 30 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Upgrade Library", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
    }
}

private struct ThemedMainWindow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            windowContent(availableWidth: proxy.size.width)
        }
        .background(theme.palette.surfaceBase)
        .foregroundStyle(theme.palette.textPrimary)
    }

    private func windowContent(availableWidth: CGFloat) -> some View {
        let displayedInspectorWidth = InspectorLayout.displayedWidth(
            requestedWidth: model.inspectorWidth,
            availableWindowWidth: availableWidth
        )

        return
            ZStack(alignment: .bottom) {
                // The sidebar runs the full height of the window and the title bar
                // spans only what is to its right. That leaves one hairline in the
                // shell instead of a horizontal rule crossing a vertical one.
                HStack(spacing: 0) {
                    if !isEditing {
                        LibrarySidebar(model: model)
                        shellDivider
                    }
                    VStack(spacing: 0) {
                        Titlebar(model: model)
                        HStack(spacing: 0) {
                            workspace
                            if model.showsEditorInspector && model.isInspectorVisible {
                                InspectorResizeDivider(
                                    model: model,
                                    displayedWidth: displayedInspectorWidth
                                )
                                UnifiedInspector(model: model, width: displayedInspectorWidth)
                            }
                        }
                    }
                }
                if let message = model.lastMessage {
                    Toast(message)
                        .padding(.bottom, 38)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(2.1))
                            model.clearMessage()
                        }
                }
            }
    }

    private var isEditing: Bool {
        model.editor != nil || model.imageEditor != nil || model.pdfEditor != nil
            || model.textEditor != nil
    }

    /// Carries on past the title bar and behind the traffic lights so the
    /// sidebar reads as one column from the very top of the window.
    private var shellDivider: some View {
        Rectangle()
            .fill(theme.palette.line)
            .frame(width: theme.metrics.hairline)
            .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder private var workspace: some View {
        if model.isSearching {
            ScrollView {
                SearchResultsView(model: model)
                    .frame(maxWidth: 1_100, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.visible)
        } else if (model.selectedWorkspace == .video && model.editor != nil)
            || (model.selectedWorkspace == .photo && model.imageEditor != nil)
            || (model.selectedWorkspace == .pdf && model.pdfEditor != nil)
            || (model.selectedWorkspace == .text && model.textEditor != nil)
        {
            WorkspaceContent(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                WorkspaceContent(model: model)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
    }
}

private struct WorkspaceContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.selectedWorkspace {
            case .inbox: InboxView(model: model)
            case .video: VideoView(model: model)
            case .photo: PhotoView(model: model)
            case .pdf: PDFView(model: model)
            case .text: TextView(model: model)
            case .convert: ConvertView(model: model)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-content-\(model.selectedWorkspace.rawValue)")
    }
}
