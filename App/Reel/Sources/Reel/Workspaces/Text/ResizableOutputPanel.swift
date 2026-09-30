import ReelAppCore
import SwiftUI

/// An output panel below the editor with its drag grip, owning its own height.
///
/// Holding the height here rather than in the editor workspace means a drag
/// re-evaluates only this panel. When the workspace owned it, every frame of a
/// drag rebuilt the whole workspace and pushed an update through the native
/// code editor, which made resizing stutter.
struct ResizableOutputPanel<Panel: View>: View {
    @State private var height = TeXOutputLayout.restoredHeight()
    @ViewBuilder let panel: (Double) -> Panel

    var body: some View {
        VStack(spacing: 0) {
            TeXOutputResizeDivider(height: $height, displayedHeight: height)
            panel(height)
        }
    }
}
