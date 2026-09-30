import AppKit
import DesignSystem
import ReelAppCore
import SwiftUI

/// The rule above the LaTeX output panel, doubling as its resize grip.
///
/// The counterpart to ``InspectorResizeDivider`` on the horizontal axis: the
/// visible line stays a hairline so the layout is unchanged, and a taller
/// invisible overlay supplies a grip that can actually be hit.
struct TeXOutputResizeDivider: View {
    @Environment(\.theme) private var theme
    @Binding var height: Double
    let displayedHeight: Double

    @State private var heightAtDragStart: Double?
    @State private var isHovering = false
    @State private var isShowingResizeCursor = false

    private var isDragging: Bool { heightAtDragStart != nil }

    var body: some View {
        Rectangle()
            .fill(theme.palette.line)
            .frame(height: theme.metrics.hairline)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        syncCursor()
                    }
                    .gesture(drag)
            }
            .onDisappear {
                heightAtDragStart = nil
                isHovering = false
                syncCursor()
            }
            .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        // Measured in window space: the grip moves as the panel resizes, so a
        // translation measured against the grip itself shifts under the
        // pointer every frame and the panel jitters.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = heightAtDragStart ?? displayedHeight
                heightAtDragStart = start
                // The panel sits below the grip, so dragging up makes it taller.
                height = TeXOutputLayout.clamped(start - value.translation.height)
                syncCursor()
            }
            .onEnded { _ in
                heightAtDragStart = nil
                TeXOutputLayout.store(height)
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
            NSCursor.resizeUpDown.push()
        } else {
            NSCursor.pop()
        }
    }
}
