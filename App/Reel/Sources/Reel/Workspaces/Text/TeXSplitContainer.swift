import DesignSystem
import ReelAppCore
import SwiftUI

/// The editor surface: an optional project navigator, the source, and an
/// optional PDF preview beside it, split at a remembered fraction.
///
/// One HStack with conditional siblings keeps the native source editor in the
/// same structural slot, so SwiftUI never recreates it when LaTeX adds a
/// preview or navigator. HSplitView was avoided because NSSplitView ignores
/// ideal widths and opened the preview at its minimum.
///
/// The fraction lives here rather than in the editor workspace so that a drag
/// re-evaluates only this container. The source and preview arrive already
/// built, so their native views are resized during a drag, not updated.
struct TeXSplitContainer<Project: View, Source: View, Preview: View>: View {
    @Environment(\.theme) private var theme
    @State private var fraction = TeXSplitLayout.restoredFraction()
    let showsProject: Bool
    let showsPreview: Bool
    let project: Project
    let source: Source
    let preview: Preview

    var body: some View {
        GeometryReader { proxy in
            let hairline = Double(theme.metrics.hairline)
            let projectWidth = showsProject ? TeXSplitLayout.projectNavigatorWidth + hairline : 0
            let splitWidth = max(0, Double(proxy.size.width) - projectWidth - hairline)
            let previewWidth = TeXSplitLayout.previewWidth(
                fraction: fraction,
                availableWidth: splitWidth
            )
            HStack(spacing: 0) {
                if showsProject {
                    project
                        .frame(width: TeXSplitLayout.projectNavigatorWidth)
                    Divider().overlay(theme.palette.line)
                }
                source
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsPreview {
                    TeXPreviewResizeDivider(
                        fraction: $fraction,
                        displayedWidth: previewWidth,
                        availableWidth: splitWidth
                    )
                    preview
                        .frame(width: previewWidth)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }
}
