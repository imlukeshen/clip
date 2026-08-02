import AIKit
import AppKit
import CoreModel
import DesignSystem
import MediaEngine
import ReelAppCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: EditorViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                editorHeader
                Divider().overlay(theme.palette.line)
                HStack(spacing: 0) {
                    toolRail
                    Divider().overlay(theme.palette.line)
                    preview
                    Divider().overlay(theme.palette.line)
                    EditorInspector(model: model, editor: editor)
                        .frame(width: 284)
                }
                Divider().overlay(theme.palette.line)
                timeline
                    .frame(height: 190)
            }

            if let notice = editor.notice {
                Toast(notice)
                    .padding(.bottom, 204)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.1))
                        editor.clearNotice()
                    }
            }
        }
        .background(theme.palette.surfaceBase)
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            Button {
                model.closeEditor()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Back to video library")

            Text(editor.document.name)
                .font(theme.type.label.font)
                .lineLimit(1)
            Text(editor.isBuilding ? "Updating preview…" : "Saved locally")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            Spacer()

            Menu {
                ForEach(editor.availableVideoAssets) { asset in
                    Button(asset.displayName) { editor.insert(asset) }
                }
                if editor.availableVideoAssets.isEmpty {
                    Text("All video assets are in this project")
                }
            } label: {
                Label("Add clip", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if editor.isExporting {
                ProgressView(value: editor.exportProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Button("Cancel") { editor.cancelExport() }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    Button("H.264 · MP4") { chooseExport(codec: .h264, container: .mp4) }
                    Button("HEVC · MP4") { chooseExport(codec: .hevc, container: .mp4) }
                    Button("ProRes 422 · MOV") {
                        chooseExport(codec: .proRes422, container: .mov)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!editor.undoManager.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")

            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(!editor.undoManager.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(theme.palette.surfacePanel)
    }

    private var toolRail: some View {
        VStack(spacing: 5) {
            ToolButton(systemName: "arrow.up.left", help: "Select", isActive: true) {}
            ToolButton(systemName: "scissors", help: "Split at playhead") {
                editor.splitAtPlayhead()
            }
            .keyboardShortcut("k", modifiers: .command)
            ToolButton(systemName: "magnifyingglass", help: "Add zoom effect") {
                guard let itemID = editor.selectedItem?.id else { return }
                editor.addZoom(to: itemID)
            }
            ToolButton(
                systemName: "cursorarrow.click.2",
                help: editor.autoZoomUnavailableReason ?? "Zoom on recorded clicks",
                isDisabled: editor.autoZoomUnavailableReason != nil
            ) {
                editor.autoZoomSelectedClip()
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .frame(width: 42)
        .background(theme.palette.surfacePanel)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: editor.player)
                .overlay {
                    if editor.isBuilding {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .padding(18)

            HStack(spacing: 15) {
                Text(timecode(editor.playhead))
                    .frame(width: 78, alignment: .leading)
                Spacer()
                Button {
                    editor.seek(to: .zero)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.plain)
                Button {
                    editor.togglePlayback()
                } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                Button {
                    editor.seek(to: editor.duration)
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(timecode(editor.duration))
                    .frame(width: 78, alignment: .trailing)
            }
            .font(theme.type.numeric.font)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(theme.palette.surfacePanel)
        }
    }

    private var timeline: some View {
        EditorTimeline(
            timeline: editor.document.timeline,
            names: editor.assetNames,
            assetDurations: editor.assetDurations,
            selection: editor.selection,
            playhead: editor.playhead,
            duration: editor.duration,
            clickMarkers: editor.timelineClickMarkers,
            accent: NSColor(theme.palette.accent),
            accentDim: NSColor(theme.palette.accentDim),
            surface: NSColor(Theme.dark.palette.surfaceSunken),
            clip: NSColor(Theme.dark.palette.surfaceRaised),
            line: NSColor(Theme.dark.palette.lineStrong),
            textPrimary: NSColor(Theme.dark.palette.textPrimary),
            textTertiary: NSColor(Theme.dark.palette.textTertiary),
            audio: NSColor(Theme.dark.palette.success),
            click: NSColor(Theme.dark.palette.click),
            caption: NSColor(Theme.dark.palette.accent),
            playheadColor: NSColor(Theme.dark.palette.danger),
            onSelect: editor.select,
            onSeek: editor.seek,
            onScrubbing: editor.setScrubbing,
            onReorder: editor.reorder,
            onTrim: editor.trim
        )
        .accessibilityLabel("Project timeline")
    }

    private func timecode(_ time: RationalTime) -> String {
        let seconds = max(0, time.seconds)
        return String(
            format: "%02d:%02d.%03d",
            Int(seconds) / 60,
            Int(seconds) % 60,
            Int(seconds * 1_000) % 1_000
        )
    }

    private func chooseExport(
        codec: ExportPreset.Codec,
        container: ExportPreset.Container
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(editor.document.name).\(container.rawValue)"
        panel.allowedContentTypes = container == .mp4 ? [.mpeg4Movie] : [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.export(
                to: url,
                preset: ExportPreset(
                    container: container,
                    codec: codec,
                    size: CGSize(
                        width: editor.document.canvas.width,
                        height: editor.document.canvas.height
                    ),
                    frameRate: editor.document.canvas.frameRate,
                    bitrate: codec == .proRes422 ? nil : 12_000_000,
                    includeAudio: true,
                    burnCaptions: true
                )
            )
        }
    }
}

private struct ToolButton: View {
    @Environment(\.theme) private var theme
    let systemName: String
    let help: String
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 30, height: 28)
                .background(isActive ? theme.palette.accentDim : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? theme.palette.accent : theme.palette.textSecondary)
        .disabled(isDisabled)
        .help(help)
    }
}

private struct EditorInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: EditorViewModel
    @State private var panel = Panel.inspector

    private enum Panel: String, CaseIterable, Identifiable {
        case inspector = "Inspector"
        case chat = "Chat"

        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider().overlay(theme.palette.line)

            if panel == .inspector {
                inspector
            } else {
                chat
            }
        }
        .background(theme.palette.surfacePanel)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            chatTranscript
            Divider().overlay(theme.palette.line)
            chatComposer
        }
    }

    private var chatTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if model.assistantMessages.isEmpty { chatEmptyState }
                    ForEach(model.assistantMessages) { message in
                        AssistantBubble(message: message).id(message.id)
                    }
                    ForEach(model.pendingAssistantActions) { action in
                        PendingActionCard(model: model, action: action)
                    }
                    if model.isAssistantWorking { ProgressView().controlSize(.small) }
                }
                .padding(12)
            }
            .onChange(of: model.assistantMessages.count) {
                if let id = model.assistantMessages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var chatEmptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Project context")
            Text("\(editor.document.timeline.video.count) clips · \(durationText)")
                .foregroundStyle(theme.palette.textSecondary)
            Text("Ask Reel to trim, split, zoom, restyle, or caption this edit.")
                .foregroundStyle(theme.palette.textTertiary)
        }
        .font(theme.type.caption.font)
    }

    private var chatComposer: some View {
        HStack(alignment: .bottom, spacing: 7) {
            TextField("Ask Reel…", text: $model.assistantDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit { model.sendAssistantMessage() }
            Button {
                model.sendAssistantMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.accent)
            .disabled(isSendDisabled)
        }
        .padding(10)
        .background(theme.palette.surfaceRaised)
    }

    private var isSendDisabled: Bool {
        model.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isAssistantWorking
    }

    @ViewBuilder private var inspector: some View {
        if let item = editor.selectedItem {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Selected clip")
                Text(editor.assetNames[item.assetID] ?? "Video clip")
                    .font(theme.type.body.font)
                    .lineLimit(2)

                LabeledContent("Source") {
                    Text(
                        "\(item.sourceRange.start.seconds, specifier: "%.2f")–\(item.sourceRange.end.seconds, specifier: "%.2f")s"
                    )
                    .font(theme.type.numeric.font)
                }

                LabeledContent("Clicks") {
                    Text("\(editor.selectedClickCount)")
                        .font(theme.type.numeric.font)
                }
                LabeledContent("Alignment") {
                    Text(editor.selectedAlignmentDescription)
                        .font(theme.type.caption.font)
                }

                Button("Zoom on clicks") {
                    editor.autoZoomSelectedClip()
                }
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.autoZoomUnavailableReason != nil)

                if let reason = editor.autoZoomUnavailableReason {
                    Text(reason)
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker(
                    "Speed",
                    selection: Binding(
                        get: { item.speed },
                        set: { editor.setSpeed($0, for: item.id) }
                    )
                ) {
                    Text("0.25×").tag(0.25)
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }

                Divider().overlay(theme.palette.line)
                SectionLabel("Effects")
                HStack(spacing: 6) {
                    EffectButton("Zoom") { editor.addZoom(to: item.id) }
                    EffectButton("Frame") { editor.addBackground(to: item.id) }
                    EffectButton("Crop") { editor.addCrop(to: item.id) }
                    EffectButton("Blur") { editor.addBlur(to: item.id) }
                }
                if item.effects.isEmpty {
                    Text("No clip effects")
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textTertiary)
                } else {
                    ForEach(item.effects) { effect in
                        HStack {
                            Text(effectName(effect.kind))
                                .font(theme.type.caption.font)
                            Spacer()
                            Button {
                                editor.removeEffect(effect.id, from: item.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.palette.textTertiary)
                        }
                    }
                }
                Spacer()
            }
            .padding(14)
        } else {
            EmptyState(
                headline: "Select a clip",
                body: "Adjust its speed or split it at the playhead."
            )
            .padding(14)
            Spacer()
        }
    }

    private var durationText: String {
        String(format: "%.1f seconds", editor.duration.seconds)
    }

    private func effectName(_ kind: EffectKind) -> String {
        switch kind {
        case .zoom: "Zoom"
        case .crop: "Crop"
        case .background: "Background"
        case .blur: "Blur"
        case .cursor: "Cursor"
        case .text: "Text"
        case .unknown(let name): name
        }
    }
}

private struct AssistantBubble: View {
    @Environment(\.theme) private var theme
    let message: AssistantMessage

    var body: some View {
        Text(message.text)
            .font(theme.type.caption.font)
            .foregroundStyle(
                message.role == .status ? theme.palette.textTertiary : theme.palette.textPrimary
            )
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                message.role == .user ? theme.palette.accentDim : theme.palette.surfaceRaised
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
            .textSelection(.enabled)
    }
}

private struct PendingActionCard: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let action: PendingAssistantAction

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Review \(action.name)").font(theme.type.label.font)
            Text(action.result.message)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textSecondary)
            HStack {
                Button("Apply") { model.approveAssistantAction(action.id) }
                    .buttonStyle(ReelBorderedButtonStyle())
                Button("Skip") { model.rejectAssistantAction(action.id) }
                    .buttonStyle(.plain)
            }
        }
        .padding(9)
        .background(theme.palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
    }
}

private struct EffectButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(theme.type.micro.font)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(theme.palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
    }
}
