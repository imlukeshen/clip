import AppKit
import Combine
import DesignSystem
import ReelAppCore
import SwiftUI

struct MainWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppModel

    var body: some View {
        content
            .environment(\.theme, colorScheme == .dark ? Theme.dark : Theme.light)
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

private struct ThemedMainWindow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Titlebar(model: model)
                WorkspaceTabs(model: model)
                Divider().overlay(theme.palette.line)
                if model.selectedWorkspace == .video, model.editor != nil {
                    WorkspaceContent(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        WorkspaceContent(model: model)
                            .frame(maxWidth: 900, alignment: .leading)
                            .padding(.horizontal, theme.metrics.spacing.xxl)
                            .padding(.top, 24)
                            .padding(.bottom, 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.visible)
                }
                StatusBar(model: model)
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
        .background(theme.palette.surfaceBase)
        .foregroundStyle(theme.palette.textPrimary)
    }
}

private struct WorkspaceContent: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.selectedWorkspace {
        case .inbox: InboxView(model: model)
        case .video: VideoView(model: model)
        case .photo: PhotoView(model: model)
        case .pdf: PDFPlaceholderView(model: model)
        case .convert: ConvertView(model: model)
        }
    }
}
