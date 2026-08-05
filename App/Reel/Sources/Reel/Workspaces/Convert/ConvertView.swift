import AppKit
import ConvertKit
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct ConvertView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @State private var showsDestinationSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceDropZone(model: model, workspace: .convert)
            queueHeader
                .padding(.top, 28)
                .padding(.bottom, 12)

            if model.shouldSuggestLibreOffice {
                Label(
                    "Install LibreOffice to enable Office format output.",
                    systemImage: "doc.badge.gearshape"
                )
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, theme.metrics.spacing.lg)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.surfaceRaised.opacity(0.56))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.control,
                        style: .continuous
                    )
                )
                .padding(.bottom, theme.metrics.spacing.lg)
                .accessibilityLabel(
                    "LibreOffice is not installed. Install it to enable Office format output."
                )
            }

            if model.conversionQueue.isEmpty {
                EmptyState(headline: "Queue is empty")
            } else {
                batchControls
                    .padding(.bottom, theme.metrics.spacing.lg)
                ConversionQueue(model: model)
                footer
                    .padding(.top, theme.metrics.spacing.lg)
            }
        }
        .sheet(isPresented: $showsDestinationSheet) {
            ConversionDestinationSheet(model: model)
                .environment(\.theme, theme)
        }
    }

    private var queueHeader: some View {
        HStack {
            SectionLabel("Conversion queue")
            Spacer()
            if !model.conversionQueue.isEmpty {
                Text(
                    "\(model.conversionQueue.count) file\(model.conversionQueue.count == 1 ? "" : "s")"
                )
                .font(theme.type.numeric.font)
                .foregroundStyle(theme.palette.textTertiary)
            }
        }
    }

    private var batchControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: theme.metrics.spacing.lg) {
                Button {
                    showsDestinationSheet = true
                } label: {
                    Label(destinationSummary, systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(ReelPlainButtonStyle())
                .disabled(model.isConverting)
                .help("Choose the output folder, naming template, and completion action")

                Spacer()

                Stepper(
                    value: Binding(
                        get: { model.conversionConcurrency },
                        set: { model.setConversionConcurrency($0) }
                    ),
                    in: 1...8
                ) {
                    Text("\(model.conversionConcurrency) at once")
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .fixedSize()
                .disabled(model.isConverting)
            }

            if model.isConverting {
                HStack(spacing: 10) {
                    ProgressView(value: model.conversionAggregateProgress)
                        .progressViewStyle(.linear)
                        .tint(theme.palette.accent)
                    Text(
                        "\(model.conversionCompletedCount) of \(model.conversionBatchTotal)"
                    )
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .monospacedDigit()
                    Button("Cancel all", action: model.cancelAllConversions)
                        .buttonStyle(ReelPlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .padding(.vertical, 14)
        .background(theme.palette.surfacePanel.opacity(0.72))
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
        )
    }

    private var footer: some View {
        HStack {
            Text("Every file continues independently; failed rows can be retried.")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            Spacer()
            Button(model.isConverting ? "Converting…" : "Convert") {
                model.convertQueuedItems()
            }
            .buttonStyle(ReelProminentButtonStyle())
            .tint(theme.palette.accent)
            .disabled(model.isConverting || !model.hasConvertibleItems)
        }
    }

    private var destinationSummary: String {
        let folder = model.conversionDestinationFolder.lastPathComponent
        let subpath = model.conversionDestination.subpathTemplate
        return subpath.isEmpty ? folder : "\(folder)/\(subpath)"
    }
}

private struct ConversionQueue: View {
    @Bindable var model: AppModel

    private var populatedKinds: [AssetKind] {
        AssetKind.allCases.filter { kind in
            model.conversionQueue.contains { $0.asset.kind == kind }
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            ForEach(populatedKinds, id: \.self) { kind in
                ConversionQueueGroup(model: model, kind: kind)
            }
        }
    }
}

private struct ConversionQueueGroup: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let kind: AssetKind

    private var items: [ConversionQueueItem] {
        model.conversionQueue.filter { $0.asset.kind == kind }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(groupTitle, systemImage: iconName)
                    .font(theme.type.label.font)
                    .foregroundStyle(theme.palette.textPrimary)
                Text("\(items.count)")
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textTertiary)
                Spacer()
                Menu("Set target for all") {
                    ForEach(model.availableConversionTargets(for: kind)) { target in
                        Button(target.displayName) {
                            model.selectConversionTarget(target, forGroup: kind)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isConverting)
            }
            .padding(.horizontal, theme.metrics.spacing.lg)
            .frame(height: 44)
            .background(theme.palette.surfaceRaised.opacity(0.56))

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ConversionQueueRow(model: model, item: item)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(theme.palette.line)
                        .frame(height: theme.metrics.hairline)
                        .padding(.leading, 58)
                }
            }
        }
        .background(theme.palette.surfacePanel)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
        )
    }

    private var groupTitle: String {
        switch kind {
        case .video: "Video"
        case .image: "Images"
        case .audio: "Audio"
        case .document: "Documents"
        case .text: "Text"
        }
    }

    private var iconName: String {
        switch kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc"
        case .text: "doc.text"
        }
    }
}

private struct ConversionQueueRow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let item: ConversionQueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: theme.metrics.spacing.lg) {
                Image(systemName: iconName)
                    .frame(width: 24)
                    .foregroundStyle(theme.palette.textTertiary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.asset.displayName)
                        .font(theme.type.label.font)
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Text(item.sourceDescription)
                        .font(theme.type.numeric.font)
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

                Picker(
                    "Target format",
                    selection: Binding(
                        get: { item.target },
                        set: { model.selectConversionTarget($0, for: item.id) }
                    )
                ) {
                    ForEach(item.availableTargets) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150, alignment: .leading)
                .disabled(isConverting)

                optionsMenu
                status
                    .frame(width: 112, alignment: .trailing)
                trailingAction
            }

            Text(item.planDescription)
                .font(theme.type.numeric.font)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(2)
                .padding(.leading, 40)

            ForEach(item.visibleWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.leading, 40)
            }

            if let failureReason {
                Text(failureReason)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.danger)
                    .textSelection(.enabled)
                    .padding(.leading, 40)
            }
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .padding(.vertical, 13)
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                model.setConversionMetadataStripping(!item.stripsMetadata, for: item.id)
            } label: {
                Label(
                    item.stripsMetadata ? "Keep metadata" : "Strip metadata",
                    systemImage: item.stripsMetadata ? "checkmark.shield" : "shield"
                )
            }
            if !item.compatiblePresets.isEmpty {
                Divider()
                ForEach(item.compatiblePresets) { preset in
                    Button {
                        model.applyConversionPreset(preset, for: item.id)
                    } label: {
                        if item.selectedPresetID == preset.id {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isConverting)
        .accessibilityLabel("Conversion options for \(item.asset.displayName)")
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .waiting:
            Text("Ready").foregroundStyle(theme.palette.textTertiary)
        case .converting:
            HStack(spacing: 6) {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(theme.palette.accent)
                    .frame(width: 52)
                Text(item.progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .foregroundStyle(theme.palette.textSecondary)
        case .completed:
            Label("Done", systemImage: "checkmark")
                .foregroundStyle(theme.palette.success)
        case .failed:
            Button("Retry") { model.retryConversion(item.id) }
                .buttonStyle(ReelPlainButtonStyle())
                .foregroundStyle(theme.palette.danger)
        case .cancelled:
            Button("Retry") { model.retryConversion(item.id) }
                .buttonStyle(ReelPlainButtonStyle())
        case .skipped:
            Button("Retry") { model.retryConversion(item.id) }
                .buttonStyle(ReelPlainButtonStyle())
                .foregroundStyle(theme.palette.textSecondary)
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        if isConverting {
            Button {
                model.cancelConversion(item.id)
            } label: {
                Image(systemName: "stop.circle")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(ReelPlainButtonStyle())
            .foregroundStyle(theme.palette.textTertiary)
            .accessibilityLabel("Cancel \(item.asset.displayName)")
        } else {
            Button {
                model.removeConversion(item.id)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(ReelPlainButtonStyle())
            .foregroundStyle(theme.palette.textTertiary)
            .accessibilityLabel("Remove \(item.asset.displayName)")
        }
    }

    private var isConverting: Bool {
        if case .converting = item.status { return true }
        return false
    }

    private var failureReason: String? {
        switch item.status {
        case .failed(let reason), .skipped(let reason): reason
        case .waiting, .converting, .completed, .cancelled: nil
        }
    }

    private var iconName: String {
        switch item.asset.kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc"
        case .text: "doc.text"
        }
    }
}

private struct ConversionDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @State private var folder: URL
    @State private var destination: ExportDestination
    @State private var conflictPolicy: ConversionConflictPolicy

    init(model: AppModel) {
        self.model = model
        _folder = State(initialValue: model.conversionDestinationFolder)
        _destination = State(initialValue: model.conversionDestination)
        _conflictPolicy = State(initialValue: model.conversionConflictPolicy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversion destination")
                .font(theme.type.title.font)

            HStack {
                Text("Folder")
                Spacer()
                Button(folder.path, action: chooseFolder)
                    .lineLimit(1)
                    .frame(maxWidth: 380, alignment: .trailing)
            }
            TextField("Subfolder template", text: $destination.subpathTemplate)
            TextField("Filename template", text: $destination.filenameTemplate)
            Picker("If a file exists", selection: $conflictPolicy) {
                Text("Rename new file").tag(ConversionConflictPolicy.rename)
                Text("Overwrite").tag(ConversionConflictPolicy.overwrite)
                Text("Skip").tag(ConversionConflictPolicy.skip)
            }
            Picker("When finished", selection: $destination.onCompletion) {
                Text("Reveal in Finder").tag(CompletionAction.reveal)
                Text("Copy paths").tag(CompletionAction.copyPath)
                Text("Do nothing").tag(CompletionAction.nothing)
            }

            Divider().overlay(theme.palette.line)
            SectionLabel("Example")
            Text(exampleURL?.path ?? validationMessage)
                .font(theme.type.numeric.font)
                .foregroundStyle(
                    exampleURL == nil ? theme.palette.danger : theme.palette.textPrimary
                )
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setConversionDestination(folder: folder, destination: destination)
                    model.setConversionConflictPolicy(conflictPolicy)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(exampleURL == nil)
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private var exampleURL: URL? {
        try? destination.resolve(
            in: folder,
            context: ExportTemplateContext(
                project: "Screen Recording",
                preset: "Web-ready MP4",
                codec: "h264",
                resolution: "1920x1080",
                duration: "30.0",
                index: 1
            ),
            extension: "mp4"
        )
    }

    private var validationMessage: String {
        do {
            try destination.validate()
            return "Choose a valid destination folder."
        } catch {
            return error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            folder = url
        }
    }
}
