import AIKit
import AppKit
import CoreModel
import DesignSystem
import LibraryStore
import MediaEngine
import ReelAppCore
import SearchEngine
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: EditorViewModel
    @State private var showsExportSheet = false
    @State private var showsMediaImporter = false
    @State private var exportCompletionAction = CompletionAction.reveal
    @State private var previewDragOffset = CGSize.zero
    @State private var previewScale = 1.0
    @State private var liveTextSpans: [OCRSpan] = []
    @State private var isRenamingProject = false
    @State private var projectNameDraft = ""
    @FocusState private var isProjectNameFocused: Bool
    @AppStorage("clip.timeline.zoom") private var timelineZoom = TimelineViewport.fitZoom

    var body: some View {
        GeometryReader { proxy in
            editorContent(availableSize: proxy.size)
        }
        .background(theme.palette.surfaceBase)
        .sheet(isPresented: $showsExportSheet) {
            ExportDestinationSheet(
                model: model,
                editor: editor,
                completionAction: $exportCompletionAction
            )
            .environment(\.theme, theme)
        }
        .fileImporter(
            isPresented: $showsMediaImporter,
            allowedContentTypes: [.movie, .image, .audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.addMediaToOpenTimeline(urls, source: .picker)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addMediaToOpenTimeline(urls, source: .drop)
            return !urls.isEmpty
        }
        .onChange(of: editor.lastExportURL) { _, url in
            guard let url else { return }
            switch exportCompletionAction {
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
            case .copyPath:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            case .nothing: break
            }
        }
        .task(id: liveTextRequestID) {
            await refreshLiveText()
        }
        .onChange(of: editor.document.id) { _, _ in
            cancelProjectRename()
        }
    }

    private func editorContent(availableSize: CGSize) -> some View {
        let compact = availableSize.width < 840
        let displayedTimelineHeight = timelineHeight(for: availableSize.height)

        return
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    editorHeader(isCompact: compact)
                    Divider().overlay(theme.palette.line)
                    HStack(spacing: 0) {
                        toolRail
                        Divider().overlay(theme.palette.line)
                        preview(isCompact: compact)
                    }
                    Divider().overlay(theme.palette.line)
                    timeline(isCompact: compact)
                        .frame(height: displayedTimelineHeight)
                }

                if let notice = editor.notice {
                    Toast(notice)
                        .padding(.bottom, displayedTimelineHeight + 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(2.1))
                            editor.clearNotice()
                        }
                }
            }
    }

    private func editorHeader(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 7 : 10) {
            Button {
                model.closeEditor()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .help("Back to video library")

            projectTitle
                .layoutPriority(1)
            if !isCompact {
                Text(editor.isBuilding ? "Updating preview…" : "Saved locally")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize()
            }
            Spacer(minLength: isCompact ? 4 : 8)

            Menu {
                Button("Paste Video, Photo, or Audio") {
                    model.pasteMediaIntoTimeline()
                }
                Button("Choose Media…") {
                    showsMediaImporter = true
                }
                Divider()
                if !editor.availableVideoAssets.isEmpty {
                    Section("Video") {
                        ForEach(editor.availableVideoAssets) { asset in
                            Button(asset.displayName) { editor.insert(asset) }
                        }
                    }
                }
                if !editor.availableAudioAssets.isEmpty {
                    Section("Audio") {
                        ForEach(editor.availableAudioAssets) { asset in
                            Button(asset.displayName) { editor.insert(asset) }
                        }
                    }
                }
                if editor.availableVideoAssets.isEmpty && editor.availableAudioAssets.isEmpty {
                    Text("No library media is available")
                }
            } label: {
                if isCompact {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                } else {
                    Label("Add media", systemImage: "plus")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add video, photos, or audio to the targeted timeline track")
            .accessibilityIdentifier("video-add-media-menu")

            Menu {
                Section("Target video track") {
                    ForEach(editor.document.timeline.videoTracks) { track in
                        Button {
                            editor.targetVideoTrack(track.id)
                        } label: {
                            if track.id == editor.targetedVideoTrackID {
                                Label(track.name, systemImage: "checkmark")
                            } else {
                                Text(track.name)
                            }
                        }
                    }
                }
                Divider()
                Button("New Overlay Track", systemImage: "square.stack.3d.up.badge.plus") {
                    editor.addOverlayTrack()
                }
            } label: {
                if isCompact {
                    Image(systemName: "square.stack.3d.up")
                        .frame(width: 24, height: 24)
                } else {
                    Label(targetedTrackName, systemImage: "square.stack.3d.up")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose where added video appears, or create an overlay track")
            .accessibilityIdentifier("video-track-target-menu")

            if editor.isExporting {
                ProgressView(value: editor.exportProgress)
                    .progressViewStyle(.linear)
                    .frame(width: isCompact ? 48 : 80)
                if isCompact {
                    Button(action: editor.cancelExport) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(ReelPlainButtonStyle())
                    .help("Cancel export")
                } else {
                    Button("Cancel") { editor.cancelExport() }
                        .buttonStyle(ReelPlainButtonStyle())
                }
            } else {
                Button {
                    showsExportSheet = true
                } label: {
                    if isCompact {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 24, height: 24)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(ReelPlainButtonStyle())
                .fixedSize()
                .help("Export the edited project")
                .accessibilityIdentifier("video-export-button")
            }

            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(!editor.undoManager.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")
            .accessibilityIdentifier("video-undo-button")

            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(!editor.undoManager.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo")
            .accessibilityIdentifier("video-redo-button")
        }
        .padding(.horizontal, 14)
        .frame(height: EditorChromeMetrics.headerHeight)
        .background(theme.palette.surfacePanel)
    }

    @ViewBuilder private var projectTitle: some View {
        if isRenamingProject {
            TextField("Project name", text: $projectNameDraft)
                .textFieldStyle(.plain)
                .font(theme.type.label.font)
                .lineLimit(1)
                .focused($isProjectNameFocused)
                .onSubmit(commitProjectRename)
                .onExitCommand(perform: cancelProjectRename)
                .padding(.horizontal, 8)
                .frame(width: projectTitleEditorWidth, height: 28)
                .background {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: theme.metrics.radius.control,
                            style: .continuous
                        )
                        .fill(theme.palette.surfaceSunken)
                        OutsideClickMonitor(isActive: isRenamingProject) {
                            commitProjectRename()
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.control,
                        style: .continuous
                    )
                    .strokeBorder(theme.palette.accentLine, lineWidth: 1)
                }
                .accessibilityIdentifier("video-project-title-field")
        } else {
            Button(action: beginProjectRename) {
                HStack(spacing: 5) {
                    Text(editor.document.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .font(theme.type.label.font)
                .contentShape(Rectangle())
            }
            .buttonStyle(ReelPlainButtonStyle())
            .help("Rename project")
            .accessibilityLabel("Rename project \(editor.document.name)")
            .accessibilityIdentifier("video-project-title")
        }
    }

    private var projectTitleEditorWidth: CGFloat {
        min(max(CGFloat(projectNameDraft.count) * 7.5 + 30, 150), 360)
    }

    private func beginProjectRename() {
        projectNameDraft = editor.document.name
        isRenamingProject = true
        Task { @MainActor in
            await Task.yield()
            isProjectNameFocused = true
            await Task.yield()
            (NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView)?.selectAll(nil)
        }
    }

    private func commitProjectRename() {
        guard isRenamingProject else { return }
        _ = editor.renameProject(to: projectNameDraft)
        isRenamingProject = false
        isProjectNameFocused = false
    }

    private func cancelProjectRename() {
        guard isRenamingProject else { return }
        projectNameDraft = editor.document.name
        isRenamingProject = false
        isProjectNameFocused = false
    }

    private var toolRail: some View {
        ScrollView(.vertical) {
            VStack(spacing: 5) {
                ToolButton(
                    systemName: "arrow.up.left",
                    title: "Select",
                    detail: "Select and move clips · V",
                    identifier: "video-tool-select",
                    isActive: editor.activeTool == .select
                ) {
                    editor.selectTool(.select)
                }
                ToolButton(
                    systemName: "scissors",
                    title: "Razor",
                    detail: "Click a clip to split it · C",
                    identifier: "video-tool-razor",
                    isActive: editor.activeTool == .razor
                ) {
                    editor.selectTool(.razor)
                }
                .keyboardShortcut("c", modifiers: [])
                ToolButton(
                    systemName: "magnet",
                    title: "Snapping",
                    detail: "Snap edits to clips and markers · S",
                    identifier: "video-tool-snapping",
                    isActive: editor.isSnappingEnabled
                ) {
                    editor.toggleSnapping()
                }
                .keyboardShortcut("s", modifiers: [])
                ToolButton(
                    systemName: "scissors.badge.ellipsis",
                    title: "Split at Playhead",
                    detail: "Cut the selected clip at the red line",
                    identifier: "video-tool-split"
                ) {
                    editor.splitAtPlayhead()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                ToolButton(
                    systemName: "trash",
                    title: "Delete Selected",
                    detail: "Remove selected video or audio · Delete",
                    identifier: "video-tool-delete",
                    isDisabled: editor.selection.isEmpty
                ) {
                    editor.deleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: [])
                ToolButton(
                    systemName: "delete.forward",
                    title: "Ripple Delete",
                    detail: "Delete a V1 clip and close the gap",
                    identifier: "video-tool-ripple-delete",
                    isDisabled: !editor.canRippleDeleteSelected
                ) {
                    editor.rippleDeleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: .shift)
                ToolButton(
                    systemName: "speaker.wave.2",
                    title: "Separate Audio",
                    detail: "Put source audio on editable A tracks",
                    identifier: "video-tool-separate-audio",
                    isDisabled: !editor.canSeparateSelectedAudio
                ) {
                    editor.separateSelectedAudio()
                }
                ToolButton(
                    systemName: "link",
                    title: editor.selectedNestID == nil ? "Nest Selection" : "Unnest Selection",
                    detail: "Shift-select media, then edit it as one group",
                    identifier: "video-tool-nest",
                    isActive: editor.selectedNestID != nil,
                    isDisabled: !editor.canNestSelection && editor.selectedNestID == nil
                ) {
                    if editor.selectedNestID == nil {
                        editor.nestSelection()
                    } else {
                        editor.unnestSelection()
                    }
                }
                ToolButton(
                    systemName: "mappin",
                    title: "Add Marker",
                    detail: "Mark the current playhead time · M",
                    identifier: "video-tool-marker"
                ) {
                    editor.addMarkerAtPlayhead()
                }
                .keyboardShortcut("m", modifiers: [])
                ToolButton(
                    systemName: "magnifyingglass",
                    title: "Zoom Effect",
                    detail: "Add a manual zoom to the selected clip",
                    identifier: "video-tool-zoom",
                    isDisabled: editor.selectedItem == nil
                ) {
                    guard let itemID = editor.selectedItem?.id else { return }
                    editor.addZoom(to: itemID)
                }
                ToolButton(
                    systemName: "cursorarrow.click.2",
                    title: "Auto Zoom",
                    detail: editor.autoZoomUnavailableReason ?? "Create zooms from recorded clicks",
                    identifier: "video-tool-auto-zoom",
                    isDisabled: editor.autoZoomUnavailableReason != nil
                ) {
                    editor.autoZoomSelectedClip()
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(width: 52)
        .background(theme.palette.surfacePanel)
        .zIndex(20)
    }

    private func preview(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let contentSize = fittedPreviewSize(in: proxy.size)
                ZStack {
                    Color.black
                    PlayerSurface(player: editor.player)
                        .frame(width: contentSize.width, height: contentSize.height)
                        .scaleEffect(previewScale)
                        .offset(previewDragOffset)

                    if !editor.isPlaying, !liveTextSpans.isEmpty {
                        LiveTextOverlay(
                            spans: liveTextSpans,
                            onSearch: model.searchLibrary,
                            onRedact: { regions in
                                editor.redactCurrentRegions(
                                    regions.map(LiveTextFrame.canvasRect(for:))
                                )
                            }
                        )
                        .frame(width: contentSize.width, height: contentSize.height)
                        .scaleEffect(previewScale)
                        .offset(previewDragOffset)
                    }

                    if editor.isBuilding {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if editor.isTimelineEmpty {
                        VStack(spacing: theme.metrics.spacing.md) {
                            if model.isAddingTimelineMedia {
                                ProgressView().controlSize(.small)
                                Text("Adding media…")
                                    .font(theme.type.label.font)
                            } else {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 30, weight: .regular))
                                    .foregroundStyle(theme.palette.textTertiary)
                                Text("Paste video, a photo, or audio")
                                    .font(theme.type.title.font)
                                Text(
                                    isCompact
                                        ? "Press Command-V, drop files here, or use Add media."
                                        : "Press Command-V, drop files here, or choose Add media. Add V2 for picture-in-picture overlays."
                                )
                                .font(theme.type.caption.font)
                                .foregroundStyle(theme.palette.textSecondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 18)
                                Button("Paste", action: model.pasteMediaIntoTimeline)
                                    .buttonStyle(ReelBorderedButtonStyle())
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("video-empty-timeline")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .clipped()
                .gesture(previewPanGesture(in: contentSize))
                .simultaneousGesture(previewMagnificationGesture)
                .overlay(alignment: .topLeading) {
                    if editor.selectedItem != nil {
                        Label("Three-finger drag to position", systemImage: "hand.draw")
                            .font(theme.type.caption.font)
                            .foregroundStyle(theme.palette.textSecondary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 9)
                            .background(theme.palette.surfacePanel.opacity(0.9))
                            .clipShape(Capsule())
                            .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if editor.selectedItem != nil,
                        editor.selectedTransform.translationX != 0
                            || editor.selectedTransform.translationY != 0
                    {
                        Button {
                            editor.resetSelectedPosition()
                        } label: {
                            Label("Center", systemImage: "scope")
                        }
                        .buttonStyle(ReelBorderedButtonStyle())
                        .padding(10)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !editor.isPlaying, !liveTextSpans.isEmpty {
                        Label("Live Text · Drag to select", systemImage: "text.viewfinder")
                            .font(theme.type.caption.font)
                            .foregroundStyle(theme.palette.textPrimary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 9)
                            .background(theme.palette.surfacePanel.opacity(0.9))
                            .clipShape(Capsule())
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Video preview")
                .accessibilityHint("Drag to position the selected clip. Pinch to scale it.")
            }
            .padding(18)

            HStack(spacing: isCompact ? 10 : 15) {
                Text(timecode(editor.playhead))
                    .frame(width: isCompact ? 68 : 78, alignment: .leading)
                Spacer()
                Button {
                    editor.togglePlayback()
                } label: {
                    Image(systemName: editor.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                }
                .buttonStyle(ReelPlainButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                .help(editor.isPlaying ? "Pause · Space" : "Play · Space")
                .accessibilityIdentifier("video-playback-toggle")
                Button {
                    editor.shuttleBackward()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(ReelPlainButtonStyle())
                .keyboardShortcut("j", modifiers: [])
                Button {
                    editor.shuttlePause()
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 18)
                }
                .buttonStyle(ReelPlainButtonStyle())
                .keyboardShortcut("k", modifiers: [])
                Button {
                    editor.shuttleForward()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(ReelPlainButtonStyle())
                .keyboardShortcut("l", modifiers: [])
                Button("I") { editor.setInPoint() }
                    .buttonStyle(ReelPlainButtonStyle())
                    .keyboardShortcut("i", modifiers: [])
                    .help("Set In point")
                Button("O") { editor.setOutPoint() }
                    .buttonStyle(ReelPlainButtonStyle())
                    .keyboardShortcut("o", modifiers: [])
                    .help("Set Out point")
                Spacer()
                Text(timecode(editor.duration))
                    .frame(width: isCompact ? 68 : 78, alignment: .trailing)
            }
            .font(theme.type.numeric.font)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(theme.palette.surfacePanel)
        }
    }

    private var liveTextRequestID: String {
        guard !editor.isPlaying, let moment = editor.sourceMomentAtPlayhead else {
            return "playing-or-empty"
        }
        return "\(moment.assetID.rawValue):\(moment.time.value)"
    }

    private func refreshLiveText() async {
        guard !editor.isPlaying, let moment = editor.sourceMomentAtPlayhead else {
            liveTextSpans = []
            return
        }
        liveTextSpans = await model.indexedText(at: moment.time, in: moment.assetID)
    }

    private func fittedPreviewSize(in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0 else { return .zero }
        let canvas = CGSize(
            width: editor.document.canvas.width,
            height: editor.document.canvas.height
        )
        guard canvas.width > 0, canvas.height > 0 else { return available }
        let scale = min(available.width / canvas.width, available.height / canvas.height)
        return CGSize(width: canvas.width * scale, height: canvas.height * scale)
    }

    private func previewPanGesture(in contentSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard editor.selectClipAtPlayheadIfNeeded() else { return }
                previewDragOffset = value.translation
            }
            .onEnded { value in
                defer { previewDragOffset = .zero }
                guard contentSize.width > 0, contentSize.height > 0 else { return }
                editor.translateSelectedClip(
                    by: NormalizedPoint(
                        x: value.translation.width / contentSize.width,
                        y: -value.translation.height / contentSize.height
                    )
                )
            }
    }

    private var previewMagnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard editor.selectClipAtPlayheadIfNeeded() else { return }
                previewScale = value
            }
            .onEnded { value in
                defer { previewScale = 1 }
                guard editor.selectClipAtPlayheadIfNeeded() else { return }
                let scale = min(max(editor.selectedTransform.scaleX * value, 0.1), 3)
                editor.setSelectedScale(scale)
            }
    }

    private func timeline(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            timelineToolbar(isCompact: isCompact)
            Divider().overlay(theme.palette.line)
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    timelineCanvas
                        .frame(
                            width: CGFloat(
                                TimelineViewport.contentWidth(
                                    viewportWidth: Double(proxy.size.width),
                                    zoom: timelineZoom
                                )
                            ),
                            height: max(proxy.size.height, timelineCanvasContentHeight)
                        )
                }
                .scrollIndicators(.visible)
                .background(theme.palette.surfaceSunken)
            }
        }
        .background(theme.palette.surfacePanel)
    }

    private func timelineToolbar(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 6 : 8) {
            Label(
                isCompact ? "\(timelineItemCount)" : clipCountLabel,
                systemImage: "rectangle.stack"
            )
            .font(theme.type.caption.font)
            .foregroundStyle(theme.palette.textSecondary)

            Divider()
                .overlay(theme.palette.line)
                .frame(height: 15)

            Label(
                editor.isSnappingEnabled ? "Snap" : "Free",
                systemImage: editor.isSnappingEnabled ? "magnet.fill" : "magnet"
            )
            .font(theme.type.caption.font)
            .foregroundStyle(
                editor.isSnappingEnabled ? theme.palette.accent : theme.palette.textTertiary
            )

            Spacer(minLength: 12)

            Button {
                setTimelineZoom(
                    TimelineViewport.stepping(timelineZoom, direction: -1)
                )
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(timelineZoom <= TimelineViewport.fitZoom)
            .keyboardShortcut("-", modifiers: .command)
            .help("Zoom out")

            Slider(
                value: Binding(
                    get: { timelineZoom },
                    set: { setTimelineZoom($0) }
                ),
                in: TimelineViewport.fitZoom...TimelineViewport.maximumZoom
            )
            .controlSize(.mini)
            .frame(width: isCompact ? 76 : 112)
            .accessibilityLabel("Timeline zoom")
            .accessibilityValue("\(Int((timelineZoom * 100).rounded())) percent")

            Button {
                setTimelineZoom(
                    TimelineViewport.stepping(timelineZoom, direction: 1)
                )
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(timelineZoom >= TimelineViewport.maximumZoom)
            .keyboardShortcut("=", modifiers: .command)
            .help("Zoom in")

            if !isCompact {
                Text("\(Int((timelineZoom * 100).rounded()))%")
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 48, alignment: .trailing)
            }

            Button {
                setTimelineZoom(TimelineViewport.fitZoom)
            } label: {
                if isCompact {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                } else {
                    Text("Fit")
                }
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(timelineZoom == TimelineViewport.fitZoom)
            .help("Fit the complete project")
            .accessibilityLabel("Fit complete project")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var clipCountLabel: String {
        let videoCount = editor.document.timeline.videoTracks.flatMap(\.items).count
        let audioCount = editor.document.timeline.audioTracks.flatMap(\.items).count
        if audioCount == 0 {
            return "\(videoCount) \(videoCount == 1 ? "clip" : "clips")"
        }
        return "\(videoCount) video · \(audioCount) audio"
    }

    private var timelineItemCount: Int {
        editor.document.timeline.videoTracks.flatMap(\.items).count
            + editor.document.timeline.audioTracks.flatMap(\.items).count
    }

    private var preferredTimelineHeight: CGFloat {
        let videoTracks = max(editor.document.timeline.videoTracks.count, 1)
        let audioTracks = max(editor.document.timeline.audioTracks.count, 1)
        return min(max(CGFloat(126 + videoTracks * 40 + audioTracks * 30), 224), 420)
    }

    private func timelineHeight(for availableHeight: CGFloat) -> CGFloat {
        let bodyHeight = max(availableHeight - EditorChromeMetrics.headerHeight, 0)
        // Preserve a useful preview at normal sizes, then let both regions
        // contract when the window is short. The timeline must never claim more
        // than the editor actually has or its tracks will extend below the window.
        let previewHeight = min(300, max(180, bodyHeight * 0.55))
        let availableForTimeline = max(bodyHeight - previewHeight, 0)
        return min(preferredTimelineHeight, availableForTimeline)
    }

    private var timelineCanvasContentHeight: CGFloat {
        let videoTracks = max(editor.document.timeline.videoTracks.count, 1)
        let audioTracks = max(editor.document.timeline.audioTracks.count, 1)
        return CGFloat(64 + videoTracks * 40 + audioTracks * 32)
    }

    private var timelineCanvas: some View {
        EditorTimeline(
            timeline: editor.document.timeline,
            names: editor.assetNames,
            assetDurations: editor.assetDurations,
            missingAssetIDs: editor.missingAssetIDs,
            selection: editor.selection,
            playhead: editor.playhead,
            duration: editor.duration,
            inPoint: editor.inPoint,
            outPoint: editor.outPoint,
            clickMarkers: editor.timelineClickMarkers,
            isSnappingEnabled: editor.isSnappingEnabled,
            activeTool: editor.activeTool,
            // The timeline is always dark, so it takes the dark tokens whichever
            // appearance the rest of the app is using.
            accent: NSColor(Theme.dark.palette.accent),
            accentDim: NSColor(Theme.dark.palette.accentDim),
            surface: NSColor(Theme.dark.palette.surfaceSunken),
            clip: NSColor(Theme.dark.palette.surfaceRaised),
            line: NSColor(Theme.dark.palette.lineStrong),
            textPrimary: NSColor(Theme.dark.palette.textPrimary),
            textTertiary: NSColor(Theme.dark.palette.textTertiary),
            audio: NSColor(Theme.dark.palette.success),
            click: NSColor(Theme.dark.palette.click),
            caption: NSColor(Theme.dark.palette.accent),
            playheadColor: NSColor(Theme.dark.palette.danger),
            clipCornerRadius: theme.metrics.radius.small,
            onSelect: editor.select,
            onSeek: editor.seek,
            onScrubbing: editor.setScrubbing,
            onReorder: editor.reorder,
            onTrim: editor.trim,
            onRazor: editor.split,
            onZoom: zoomTimeline
        )
        .accessibilityIdentifier("video-timeline")
        .help(
            "Three-finger drag clips to reorder or trim. Scroll to pan; pinch or Option-scroll to zoom."
        )
        .accessibilityLabel("Project timeline")
        .accessibilityHint(
            "Drag clips or their edges to reorder and trim. Scroll to pan and pinch to zoom."
        )
    }

    private func zoomTimeline(by factor: CGFloat) {
        setTimelineZoom(
            TimelineViewport.zooming(timelineZoom, by: Double(factor))
        )
    }

    private func setTimelineZoom(_ zoom: Double) {
        timelineZoom = TimelineViewport.clampedZoom(zoom)
    }

    private var targetedTrackName: String {
        editor.document.timeline.videoTracks.first {
            $0.id == editor.targetedVideoTrackID
        }?.name ?? "V1"
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

}

private struct ExportDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var editor: EditorViewModel
    @Binding var completionAction: CompletionAction
    @State private var baseFolder =
        FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
    @State private var destination = ExportDestination(bookmarkKey: "default")
    @State private var codec = ExportPreset.Codec.h264

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Project").font(theme.type.title.font)
            Picker("Preset", selection: $codec) {
                Text("H.264 · MP4").tag(ExportPreset.Codec.h264)
                Text("HEVC · MP4").tag(ExportPreset.Codec.hevc)
                Text("ProRes 422 · MOV").tag(ExportPreset.Codec.proRes422)
            }
            HStack {
                Text("Destination")
                Spacer()
                Menu(baseFolder.lastPathComponent) {
                    ForEach(recentFolders, id: \.path) { folder in
                        Button(folder.path) { baseFolder = folder }
                    }
                    Divider()
                    Button("Library Media") {
                        baseFolder = LibraryLayout.media(in: model.libraryRoot)
                    }
                    Button("Choose…", action: chooseFolder)
                }
                .frame(maxWidth: 320)
            }
            TextField("Subfolder template", text: $destination.subpathTemplate)
            TextField("Filename template", text: $destination.filenameTemplate)
            Picker("When finished", selection: $destination.onCompletion) {
                Text("Reveal in Finder").tag(CompletionAction.reveal)
                Text("Copy path").tag(CompletionAction.copyPath)
                Text("Do nothing").tag(CompletionAction.nothing)
            }
            Divider().overlay(theme.palette.line)
            SectionLabel("Resolved path")
            Text(resolvedURL?.path ?? validationMessage)
                .font(theme.type.numeric.font)
                .foregroundStyle(
                    resolvedURL == nil ? theme.palette.danger : theme.palette.textPrimary
                )
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") { startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolvedURL == nil)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear(perform: loadPreference)
    }

    private var container: ExportPreset.Container { codec == .proRes422 ? .mov : .mp4 }

    private var resolvedURL: URL? {
        try? destination.resolve(
            in: baseFolder,
            context: ExportTemplateContext(
                project: editor.document.name,
                preset: codec == .proRes422 ? "prores-422" : "1080p",
                codec: codec.rawValue,
                resolution: "\(editor.document.canvas.width)x\(editor.document.canvas.height)",
                duration: String(format: "%.1f", editor.duration.seconds)
            ),
            extension: container.rawValue
        )
    }

    private var validationMessage: String {
        do {
            try destination.validate()
            return "Choose a valid destination."
        } catch {
            return error.localizedDescription
        }
    }

    private var preferenceKey: String { "reel.export.\(editor.document.id.rawValue)" }

    private var recentFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: "reel.export.recents") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            baseFolder = url
        }
    }

    private func startExport() {
        guard let url = resolvedURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch { return }
        completionAction = destination.onCompletion
        savePreference()
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
        dismiss()
    }

    private func loadPreference() {
        guard let data = UserDefaults.standard.data(forKey: preferenceKey),
            let preference = try? JSONDecoder().decode(SavedExportPreference.self, from: data)
        else { return }
        baseFolder = URL(fileURLWithPath: preference.folder, isDirectory: true)
        destination = preference.destination
        codec = ExportPreset.Codec(rawValue: preference.codec) ?? .h264
    }

    private func savePreference() {
        let preference = SavedExportPreference(
            folder: baseFolder.path,
            destination: destination,
            codec: codec.rawValue
        )
        UserDefaults.standard.set(try? JSONEncoder().encode(preference), forKey: preferenceKey)
        var recent = UserDefaults.standard.stringArray(forKey: "reel.export.recents") ?? []
        recent.removeAll { $0 == baseFolder.path }
        recent.insert(baseFolder.path, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(6)), forKey: "reel.export.recents")
    }
}

private struct SavedExportPreference: Codable {
    var folder: String
    var destination: ExportDestination
    var codec: String
}

private struct ToolButton: View {
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    let systemName: String
    let title: String
    let detail: String
    let identifier: String
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        ZStack {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(ReelIconButtonStyle(isActive: isActive))
            .disabled(isDisabled)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if isHovered {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.type.label.font)
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(detail)
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .fixedSize()
                .background(theme.palette.surfaceRaised)
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
                    .strokeBorder(theme.palette.lineStrong, lineWidth: theme.metrics.hairline)
                }
                .shadow(color: .black.opacity(0.28), radius: 9, y: 4)
                .offset(x: 43)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help("\(title): \(detail)")
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityIdentifier(identifier)
        .zIndex(isHovered ? 100 : 0)
    }
}

struct EditorInspector: View {
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
            .padding(.horizontal, 12)
            .frame(height: EditorChromeMetrics.headerHeight)

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
            chatComposer
        }
    }

    private var chatTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if model.assistantMessages.isEmpty { chatEmptyState }
                    ForEach(model.assistantMessages) { message in
                        AssistantChatBubble(message: message).id(message.id)
                    }
                    ForEach(model.pendingAssistantActions) { action in
                        PendingActionCard(model: model, action: action)
                    }
                    if model.isAssistantWorking { ProgressView().controlSize(.small) }
                }
                .padding(14)
            }
            .onChange(of: model.assistantMessages.count) {
                if let id = model.assistantMessages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var chatEmptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Project context")
            Text("\(editor.timelineMediaCount) items · \(durationText)")
                .foregroundStyle(theme.palette.textSecondary)
            Text("Ask Clip to trim, split, zoom, restyle, or caption this edit.")
                .foregroundStyle(theme.palette.textTertiary)
        }
        .font(theme.type.caption.font)
    }

    private var chatComposer: some View {
        AssistantChatComposer(
            draft: $model.assistantDraft,
            isWorking: model.isAssistantWorking,
            send: model.sendAssistantMessage
        )
    }

    @ViewBuilder private var inspector: some View {
        if let item = editor.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let track = editor.targetedVideoTrack {
                        SectionLabel("Target track · \(track.name)")
                        HStack(spacing: 6) {
                            EffectButton(track.isEnabled ? "Disable" : "Enable") {
                                editor.toggleTargetTrackEnabled()
                            }
                            EffectButton(track.isLocked ? "Unlock" : "Lock") {
                                editor.toggleTargetTrackLocked()
                            }
                            EffectButton(track.isMuted ? "Unmute" : "Mute") {
                                editor.toggleTargetTrackMuted()
                            }
                            EffectButton(track.isSolo ? "Unsolo" : "Solo") {
                                editor.toggleTargetTrackSolo()
                            }
                        }
                        KeyframeSlider(
                            title: "Gain",
                            value: Binding(
                                get: { editor.targetedGain },
                                set: { value in editor.setTargetedGain(value) }
                            ),
                            range: -60...12,
                            suffix: " dB",
                            hasKeyframe: editor.hasGainKeyframeAtPlayhead,
                            addKeyframe: { editor.setGainKeyframe() }
                        )
                        Divider().overlay(theme.palette.line)
                    }
                    SectionLabel(
                        editor.selectedTrackKind == .audio ? "Selected audio" : "Selected video"
                    )
                    Text(editor.assetNames[item.assetID] ?? "Media clip")
                        .font(theme.type.body.font)
                        .lineLimit(2)

                    LabeledContent("Track") {
                        Text(editor.selectedTrackName ?? "—")
                            .font(theme.type.numeric.font)
                    }

                    LabeledContent("Source") {
                        Text(
                            "\(item.sourceRange.start.seconds, specifier: "%.2f")–\(item.sourceRange.end.seconds, specifier: "%.2f")s"
                        )
                        .font(theme.type.numeric.font)
                    }

                    SectionLabel("Timeline actions")
                    HStack(spacing: 6) {
                        EffectButton("Delete") { editor.deleteSelected() }
                            .accessibilityIdentifier("inspector-delete-selected")
                        if editor.selectedTrackKind == .video {
                            EffectButton("Separate audio") { editor.separateSelectedAudio() }
                                .disabled(!editor.canSeparateSelectedAudio)
                                .accessibilityIdentifier("inspector-separate-audio")
                            EffectButton("Ripple delete") { editor.rippleDeleteSelected() }
                                .disabled(!editor.canRippleDeleteSelected)
                                .accessibilityIdentifier("inspector-ripple-delete")
                        }
                    }
                    HStack(spacing: 6) {
                        if editor.selectedNestID == nil {
                            EffectButton("Nest selection") { editor.nestSelection() }
                                .disabled(!editor.canNestSelection)
                        } else {
                            EffectButton("Unnest selection") { editor.unnestSelection() }
                        }
                        Text(
                            editor.selectedNestID == nil
                                ? "Shift-click clips to select more than one."
                                : "This media edits as one group."
                        )
                        .font(theme.type.micro.font)
                        .foregroundStyle(theme.palette.textTertiary)
                    }

                    Divider().overlay(theme.palette.line)

                    if editor.selectedTrackKind == .video {
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

                    if editor.selectedTrackKind == .video {
                        KeyframeSlider(
                            title: "Opacity",
                            value: Binding(
                                get: { editor.selectedOpacity },
                                set: { value in editor.setSelectedOpacity(value) }
                            ),
                            range: 0...1,
                            suffix: "",
                            hasKeyframe: editor.hasOpacityKeyframeAtPlayhead,
                            addKeyframe: { editor.setOpacityKeyframe() }
                        )
                        KeyframeSlider(
                            title: "Scale",
                            value: Binding(
                                get: { editor.selectedTransform.scaleX },
                                set: { value in editor.setSelectedScale(value) }
                            ),
                            range: 0.1...3,
                            suffix: "×",
                            hasKeyframe: editor.hasTransformKeyframeAtPlayhead,
                            addKeyframe: { editor.setTransformKeyframe() }
                        )
                    }

                    Divider().overlay(theme.palette.line)
                    SectionLabel("Precision edit")
                    HStack(spacing: 6) {
                        EffectButton("Roll +1f") { editor.rollSelected() }
                        EffectButton("Slip +1f") { editor.slipSelected() }
                        EffectButton("Slide +1f") { editor.slideSelected() }
                    }
                    HStack(spacing: 6) {
                        if editor.selectedTrackKind == .video {
                            EffectButton("Dissolve") { editor.addCrossDissolve() }
                        }
                        EffectButton("Audio fade") { editor.addAudioFade() }
                    }
                    HStack(spacing: 6) {
                        EffectButton("Copy attrs") { editor.copySelectedAttributes() }
                        EffectButton("Paste attrs") { editor.pasteAttributesToSelection() }
                    }
                    HStack(spacing: 6) {
                        EffectButton("Insert") { editor.insertSelectedSource(overwrite: false) }
                        EffectButton("Overwrite") { editor.insertSelectedSource(overwrite: true) }
                    }

                    if editor.selectedTrackKind == .video {
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
                                    if effect.kind == .blur || effect.kind == .zoom {
                                        Button {
                                            editor.setEffectKeyframe(effect)
                                        } label: {
                                            Image(systemName: "diamond")
                                        }
                                        .buttonStyle(ReelPlainButtonStyle())
                                        .foregroundStyle(theme.palette.accent)
                                        .help("Add keyframe at playhead")
                                    }
                                    Button {
                                        editor.removeEffect(effect.id, from: item.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(ReelPlainButtonStyle())
                                    .foregroundStyle(theme.palette.textTertiary)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        } else {
            EmptyState(headline: "No clip selected")
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
                    .buttonStyle(ReelPlainButtonStyle())
            }
        }
        .padding(9)
        .background(theme.palette.surfaceRaised)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
        )
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
            .buttonStyle(ReelPlainButtonStyle())
            .font(theme.type.micro.font)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(theme.palette.surfaceRaised)
            .clipShape(
                RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
            )
    }
}

private struct KeyframeSlider: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    let hasKeyframe: Bool
    let addKeyframe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(theme.type.caption.font)
                Spacer()
                Text("\(value, specifier: "%.2f")\(suffix)")
                    .font(theme.type.numeric.font)
                Button(action: addKeyframe) {
                    Image(systemName: hasKeyframe ? "diamond.fill" : "diamond")
                }
                .buttonStyle(ReelPlainButtonStyle())
                .foregroundStyle(theme.palette.accent)
                .help("Set keyframe at playhead")
            }
            Slider(value: $value, in: range)
        }
    }
}
