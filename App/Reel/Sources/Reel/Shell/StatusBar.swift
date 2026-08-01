import DesignSystem
import ReelAppCore
import SwiftUI

struct StatusBar: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: theme.metrics.spacing.lg) {
            Text(model.libraryRoot.path(percentEncoded: false))
                .lineLimit(1)
            Text("Local only")
            Spacer()
            Text("\(model.assets.count) files")
            Text(byteCount)
        }
        .font(theme.type.numeric.font)
        .foregroundStyle(theme.palette.textTertiary)
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(theme.palette.surfaceBase)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.palette.line).frame(height: theme.metrics.hairline)
        }
    }

    private var byteCount: String {
        let total = model.assets.reduce(Int64.zero) { $0 + $1.byteSize }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
