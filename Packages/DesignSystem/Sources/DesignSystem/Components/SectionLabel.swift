import SwiftUI

public struct SectionLabel: View {
    @Environment(\.theme) private var theme
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(theme.type.sectionLabel.font)
            .tracking(0.5)
            .foregroundStyle(theme.palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
