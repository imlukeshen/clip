import AppKit
import CoreModel
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct AssetGrid: View {
    @Bindable var model: AppModel
    let assets: [AssetRecord]

    @State private var gridWidth: CGFloat = 0
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?

    private let columns = [
        GridItem(.adaptive(minimum: 152, maximum: 210), spacing: 14)
    ]

    var body: some View {
        if assets.isEmpty {
            EmptyState(
                headline: "This workspace is ready",
                body: "Drop files above or capture something new."
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(model.selection.selected.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(model.selection.selected.isEmpty ? 0 : 1)
                    Spacer()
                    Button("Select all") {
                        AppCommandRouter.run("asset.selectAll", in: model)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.selection.selected.count == assets.count)
                    Picker("Sort", selection: $model.assetSort) {
                        Text("Name").tag(AssetSort.name)
                        Text("Kind").tag(AssetSort.kind)
                        Text("Duration").tag(AssetSort.duration)
                        Text("Size").tag(AssetSort.size)
                        Text("Modified").tag(AssetSort.modified)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Picker("View", selection: $model.browserViewMode) {
                        Image(systemName: "square.grid.2x2").tag(BrowserViewMode.grid)
                        Image(systemName: "list.bullet").tag(BrowserViewMode.list)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 72)
                }

                if model.browserViewMode == .grid {
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
                                }
                            ) {
                                AssetThumbnail(asset: asset, libraryRoot: model.libraryRoot)
                            }
                            .draggable(dragValue(for: asset))
                            .contextMenu {
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
                } else {
                    AssetList(model: model, assets: assets, modifiers: currentModifiers)
                }
            }
            .onAppear { model.selection.setItems(assetIDs) }
            .onChange(of: assetIDs) { _, ids in model.selection.setItems(ids) }
        }
    }

    private var assetIDs: [AssetID] { assets.map(\.id) }

    private func dragValue(for asset: AssetRecord) -> String {
        let ids = model.selection.selected.contains(asset.id)
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
                Button {
                    model.selectAsset(asset.id, modifiers: modifiers)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: asset.kind)).frame(width: 18)
                        Text(asset.displayName)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(asset.kind.rawValue.capitalized).frame(width: 90, alignment: .leading)
                        Text(duration(asset)).frame(width: 80, alignment: .trailing)
                        Text(ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))
                            .frame(width: 90, alignment: .trailing)
                        Text(asset.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .frame(width: 120, alignment: .trailing)
                    }
                    .font(theme.type.caption.font)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(
                        model.selection.selected.contains(asset.id)
                            ? theme.palette.accentDim : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .draggable(
                    "assets:" + (
                        model.selection.selected.contains(asset.id)
                            ? model.selection.selected : Set([asset.id])
                    ).map(\.rawValue).sorted().joined(separator: ",")
                )
                .contextMenu {
                    Button("Reveal in Finder") {
                        if !model.selection.selected.contains(asset.id) { model.selectAsset(asset.id) }
                        model.revealSelectionInFinder()
                    }
                    Button("Move to Trash", role: .destructive) {
                        if !model.selection.selected.contains(asset.id) { model.selectAsset(asset.id) }
                        AppCommandRouter.run("asset.delete", in: model)
                    }
                }
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

    private func duration(_ asset: AssetRecord) -> String {
        guard let value = asset.duration else { return "—" }
        let seconds = max(0, Int(value.seconds.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func icon(for kind: AssetKind) -> String {
        switch kind {
        case .video: "video"
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc"
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
