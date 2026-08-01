import DesignSystem
import ReelAppCore
import SwiftUI

struct PDFPlaceholderView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    private let planned = [
        "Read embedded font descriptors so edits use the document's real typeface.",
        "Warn when subset fonts do not contain the glyphs an edit needs.",
        "Convert to Markdown with layout-aware tables and headings.",
        "Run OCR for scanned pages on-device by default.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(
                title: "PDF",
                subtitle:
                    "Not in the first release. Dropping a PDF still routes here for the planned workflow."
            )
            WorkspaceDropZone(model: model, workspace: .pdf)
            SectionLabel("Planned")
                .padding(.top, 28)
                .padding(.bottom, 11)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(planned.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 11) {
                        Text(String(format: "%02d", index + 1))
                            .font(theme.type.numeric.font)
                            .foregroundStyle(theme.palette.textTertiary)
                        Text(item)
                            .font(theme.type.label.font)
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineSpacing(3)
                    }
                    .padding(.vertical, 7)
                    Divider().overlay(theme.palette.line)
                }
            }
            .frame(maxWidth: 560)
            Text(
                "PDF editing is deferred because it has a separate rendering engine, licensing surface, and set of failure modes."
            )
            .font(theme.type.caption.font)
            .foregroundStyle(theme.palette.textTertiary)
            .lineSpacing(3)
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.top, 14)
        }
    }
}
