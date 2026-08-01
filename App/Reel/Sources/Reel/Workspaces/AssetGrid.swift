import AppKit
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct AssetGrid: View {
    @Bindable var model: AppModel
    let assets: [AssetRecord]

    private let columns = [
        GridItem(.adaptive(minimum: 152, maximum: 210), spacing: 10)
    ]

    var body: some View {
        if assets.isEmpty {
            EmptyState(
                headline: "This workspace is ready",
                body: "Drop files above or capture something new."
            )
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(assets) { asset in
                    AssetCard(
                        title: asset.displayName,
                        metadata: metadata(for: asset),
                        duration: duration(for: asset),
                        state: model.selectedAssetID == asset.id.rawValue ? .selected : .normal,
                        action: { model.selectedAssetID = asset.id.rawValue }
                    ) {
                        AssetThumbnail(asset: asset, libraryRoot: model.libraryRoot)
                    }
                }
            }
        }
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
