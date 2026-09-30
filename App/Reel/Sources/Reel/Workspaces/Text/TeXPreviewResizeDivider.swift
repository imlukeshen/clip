import AppKit
import DesignSystem
import ReelAppCore
import SwiftUI

/// The rule between the LaTeX source and its PDF preview, doubling as the
/// preview's resize grip.
///
/// Built like ``InspectorResizeDivider`` rather than on `HSplitView`, whose
/// NSSplitView ignores ideal widths and opened the preview at its minimum.
/// Double-clicking the grip restores the default split.
struct TeXPreviewResizeDivider: View {
    @Environment(\.theme) private var theme
    @Binding var fraction: Double
    let displayedWidth: Double
    let availableWidth: Double

    @State private var widthAtDragStart: Double?
    @State private var isHovering = false
    @State private var isShowingResizeCursor = false

    private var isDragging: Bool { widthAtDragStart != nil }

    var body: some View {
        Rectangle()
            .fill(theme.palette.line)
            .frame(width: theme.metrics.hairline)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        syncCursor()
                    }
                    .onTapGesture(count: 2) {
                        fraction = TeXSplitLayout.defaultPreviewFraction
                        TeXSplitLayout.store(fraction)
                    }
                    .gesture(drag)
            }
            .onDisappear {
                widthAtDragStart = nil
                isHovering = false
                syncCursor()
            }
            .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        // Measured in window space: the grip moves as the panes resize, so a
        // translation measured against the grip itself shifts under the
        // pointer every frame and the divider jitters.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = widthAtDragStart ?? displayedWidth
                widthAtDragStart = start
                // The preview is on the trailing edge, so dragging left widens it.
                let width = TeXSplitLayout.previewWidth(
                    fraction: TeXSplitLayout.fraction(
                        previewWidth: start - value.translation.width,
                        availableWidth: availableWidth
                    ),
                    availableWidth: availableWidth
                )
                fraction = TeXSplitLayout.fraction(
                    previewWidth: width,
                    availableWidth: availableWidth
                )
                syncCursor()
            }
            .onEnded { _ in
                widthAtDragStart = nil
                TeXSplitLayout.store(fraction)
                syncCursor()
            }
    }

    /// Push and pop in matched pairs, holding the cursor for the whole drag even
    /// when the pointer wanders off the grip.
    private func syncCursor() {
        let shouldShow = isHovering || isDragging
        guard shouldShow != isShowingResizeCursor else { return }
        isShowingResizeCursor = shouldShow
        if shouldShow {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
    }
}
