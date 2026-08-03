import AppKit
import CoreModel
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct AssetGrid: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let assets: [AssetRecord]

    @State private var gridWidth: CGFloat = 0
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?

    private let columns = [
        GridItem(.adaptive(minimum: 152, maximum: 210), spacing: 14)
    ]

    var body: some View {
        Group {
            if assets.isEmpty {
                emptyState
                    .padding(.vertical, 26)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    browserToolbar

                    if model.browserViewMode == .grid {
                        grid
                    } else {
                        AssetList(model: model, assets: assets, modifiers: currentModifiers)
                    }
                }
            }
        }
        .onAppear { model.selection.setItems(assetIDs) }
        .onChange(of: assetIDs) { _, ids in model.selection.setItems(ids) }
    }

    private var browserToolbar: some View {
        HStack(spacing: 10) {
            Text("\(assets.count) item\(assets.count == 1 ? "" : "s")")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textSecondary)
            if !model.selection.selected.isEmpty {
                Text("\(model.selection.selected.count) selected")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.accent)
            }
            Spacer()
            Button {
                AppCommandRouter.run("asset.selectAll", in: model)
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(ReelPlainButtonStyle())
            .disabled(model.selection.selected.count == assets.count)
            .help("Select all")
            Divider().frame(height: 18)
            Picker("Sort", selection: $model.assetSort) {
                Text("Name").tag(AssetSort.name)
                Text("Kind").tag(AssetSort.kind)
                Text("Duration").tag(AssetSort.duration)
                Text("Size").tag(AssetSort.size)
                Text("Modified").tag(AssetSort.modified)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 108)
            Picker("View", selection: $model.browserViewMode) {
                Image(systemName: "square.grid.2x2").tag(BrowserViewMode.grid)
                Image(systemName: "list.bullet").tag(BrowserViewMode.list)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 72)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(theme.palette.surfacePanel)
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.control)
                .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(assets) { asset in
                AssetCard(
                    title: asset.displayName,
                    metadata: metadata(for: asset),
                    duration: duration(for: asset),
                    state: model.selection.selected.contains(asset.id)
                        ? .selected : .normal,
                    action: {
                        model.selectAsset(asset.id, modifiers: currentModifiers)
                    },
                    openAction: {
                        model.activateAsset(asset.id)
                    }
                ) {
                    AssetThumbnail(asset: asset, libraryRoot: model.libraryRoot)
                }
                .opacity(asset.isMissing ? 0.45 : 1)
                .overlay(alignment: .topLeading) {
                    if asset.isMissing {
                        Text("Missing")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.75))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }
                .draggable(dragValue(for: asset))
                .contextMenu {
                    Button("Open") { model.activateAsset(asset.id) }
                        .disabled(asset.isMissing)
                    Divider()
                    if asset.isMissing {
                        Button("Locate…") { locate(asset) }
                        Divider()
                    }
                    Button("Reveal in Finder") {
                        if !model.selection.selected.contains(asset.id) {
                            model.selectAsset(asset.id)
                        }
                        model.revealSelectionInFinder()
                    }
                    Button("Move to Trash", role: .destructive) {
                        if !model.selection.selected.contains(asset.id) {
                            model.selectAsset(asset.id)
                        }
                        AppCommandRouter.run("asset.delete", in: model)
                    }
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { gridWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in gridWidth = width }
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            if let rect = marqueeRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .stroke(Color.accentColor, lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .simultaneousGesture(marqueeGesture)
        .focusable()
        .onMoveCommand(perform: moveSelection)
    }

    @ViewBuilder private var emptyState: some View {
        if model.isSearching {
            EmptyState(
                headline: "No results for “\(model.searchQuery)”",
                body: "Try a file name, folder, type, format, or codec.",
                actionTitle: "Clear search",
                action: model.clearSearch
            )
        } else {
            EmptyState(
                headline: "Nothing here yet",
                body: "Drop files above or choose files to add them to Reel."
            )
        }
    }

    private var assetIDs: [AssetID] { assets.map(\.id) }

    private func dragValue(for asset: AssetRecord) -> String {
        let ids =
            model.selection.selected.contains(asset.id)
            ? model.selection.selected : Set([asset.id])
        return "assets:" + ids.map(\.rawValue).sorted().joined(separator: ",")
    }

    private var currentModifiers: ReelAppCore.EventModifiers {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        var result: ReelAppCore.EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if marqueeStart == nil { marqueeStart = value.startLocation }
                marqueeCurrent = value.location
            }
            .onEnded { _ in
                if let rect = marqueeRect {
                    model.selection.marquee(
                        rect,
                        in: calculatedLayout,
                        additive: currentModifiers.contains(.command)
                    )
                }
                marqueeStart = nil
                marqueeCurrent = nil
            }
    }

    private var calculatedLayout: ReelAppCore.GridLayout {
        let spacing: CGFloat = 10
        let count = max(1, Int((gridWidth + spacing) / (152 + spacing)))
        let width = min(210, (gridWidth - CGFloat(count - 1) * spacing) / CGFloat(count))
        let height = width / 1.6 + 58
        var frames: [AssetID: CGRect] = [:]
        for (index, id) in assetIDs.enumerated() {
            let row = index / count
            let column = index % count
            frames[id] = CGRect(
                x: CGFloat(column) * (width + spacing),
                y: CGFloat(row) * (height + spacing),
                width: width,
                height: height
            )
        }
        return ReelAppCore.GridLayout(frames: frames)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let columns = max(1, Int((gridWidth + 10) / 162))
        let offset: Int
        switch direction {
        case .left: offset = -1
        case .right: offset = 1
        case .up: offset = -columns
        case .down: offset = columns
        @unknown default: return
        }
        model.selection.move(by: offset, extending: currentModifiers.contains(.shift))
    }

    private func metadata(for asset: AssetRecord) -> String {
        let format = (asset.container ?? asset.kind.rawValue).uppercased()
        let size = ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file)
        return "\(format) · \(size)"
    }

    private func duration(for asset: AssetRecord) -> String? {
        guard let duration = asset.duration else { return nil }
        let totalSeconds = max(0, Int(duration.seconds.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func locate(_ asset: AssetRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.locateMissingAsset(asset.id, at: url)
        }
    }
}

private struct AssetList: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let assets: [AssetRecord]
    let modifiers: ReelAppCore.EventModifiers

    var body: some View {
        LazyVStack(spacing: 1) {
            HStack(spacing: 12) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Kind").frame(width: 90, alignment: .leading)
                Text("Duration").frame(width: 80, alignment: .trailing)
                Text("Size").frame(width: 90, alignment: .trailing)
                Text("Modified").frame(width: 120, alignment: .trailing)
            }
            .font(theme.type.caption.font)
            .foregroundStyle(theme.palette.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 28)

            ForEach(assets) { asset in
                AssetListRow(model: model, asset: asset, modifiers: modifiers)
            }
        }
        .focusable()
        .onMoveCommand { direction in
            let offset: Int
            switch direction {
            case .up: offset = -1
            case .down: offset = 1
            default: return
            }
            model.selection.move(by: offset, extending: modifiers.contains(.shift))
        }
    }

}

private struct AssetListRow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let asset: AssetRecord
    let modifiers: ReelAppCore.EventModifiers
    @State private var isHovered = false

    var body: some View {
        Button {
            model.selectAsset(asset.id, modifiers: modifiers)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 18)
                Text(asset.displayName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(asset.kind.rawValue.capitalized).frame(width: 90, alignment: .leading)
                Text(duration).frame(width: 80, alignment: .trailing)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: asset.byteSize,
                        countStyle: .file
                    )
                )
                .frame(width: 90, alignment: .trailing)
                Text(asset.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .frame(width: 120, alignment: .trailing)
            }
            .font(theme.type.caption.font)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReelPlainButtonStyle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                model.activateAsset(asset.id)
            }
        )
        .onHover { isHovered = $0 }
        .opacity(asset.isMissing ? 0.45 : 1)
        .draggable(dragValue)
        .contextMenu { contextMenu }
    }

    private var rowBackground: Color {
        if model.selection.selected.contains(asset.id) { return theme.palette.accentDim }
        return isHovered ? theme.palette.surfaceRaised : Color.clear
    }

    private var dragValue: String {
        let ids =
            model.selection.selected.contains(asset.id)
            ? model.selection.selected : Set([asset.id])
        return "assets:" + ids.map(\.rawValue).sorted().joined(separator: ",")
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Open") { model.activateAsset(asset.id) }
            .disabled(asset.isMissing)
        Divider()
        if asset.isMissing {
            Button("Locate…", action: locate)
            Divider()
        }
        Button("Reveal in Finder") {
            selectIfNeeded()
            model.revealSelectionInFinder()
        }
        Button("Move to Trash", role: .destructive) {
            selectIfNeeded()
            AppCommandRouter.run("asset.delete", in: model)
        }
    }

    private var duration: String {
        guard let value = asset.duration else { return "—" }
        let seconds = max(0, Int(value.seconds.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var icon: String {
        switch asset.kind {
        case .video: "video"
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc"
        }
    }

    private func selectIfNeeded() {
        if !model.selection.selected.contains(asset.id) {
            model.selectAsset(asset.id)
        }
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.locateMissingAsset(asset.id, at: url)
        }
    }
}

private struct AssetThumbnail: View {
    @Environment(\.theme) private var theme
    let asset: AssetRecord
    let libraryRoot: URL

    var body: some View {
        if let thumbnailPath = asset.thumbnailPath,
            let image = NSImage(
                contentsOf: libraryRoot.appendingPathComponent(thumbnailPath)
            )
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                Text(asset.container?.uppercased() ?? asset.kind.rawValue.uppercased())
                    .font(theme.type.numeric.font)
            }
            .foregroundStyle(theme.palette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var systemImage: String {
        switch asset.kind {
        case .video: "video"
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc"
        }
    }
}
