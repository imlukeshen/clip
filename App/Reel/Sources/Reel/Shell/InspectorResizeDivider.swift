import AppKit
import DesignSystem
import ReelAppCore
import SwiftUI

/// The rule between the workspace and the inspector, which doubles as the
/// inspector's resize grip the way a Finder pane divider does.
///
/// The line itself stays a hairline so the layout is unchanged; a wider,
/// invisible overlay supplies a grip you can actually hit.
struct InspectorResizeDivider: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let displayedWidth: Double

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
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = widthAtDragStart ?? displayedWidth
                widthAtDragStart = start
                // The inspector is on the trailing edge, so dragging left widens it.
                model.setInspectorWidth(start - value.translation.width)
                syncCursor()
            }
            .onEnded { _ in
                widthAtDragStart = nil
                syncCursor()
            }
    }

    /// Push and pop in matched pairs, and hold the cursor for the whole drag
    /// even when the pointer wanders off the grip.
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
